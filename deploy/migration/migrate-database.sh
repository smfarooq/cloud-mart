#!/usr/bin/env bash
# Phase 15, wave 2: an offline migration of the legacy shop's database to Azure Database for PostgreSQL, with the
# PostgreSQL tools themselves (pg_dump and pg_restore) and an Entra token instead of a password. It runs ON the
# simulated on-premises server, started from your machine with Run Command:
#
#   az vm run-command invoke -g <legacy resource group> -n <legacy server> --command-id RunShellScript \
#     --scripts @deploy/migration/migrate-database.sh \
#     --parameters "<server>.postgres.database.azure.com" "<legacy server name>"
#
# "Offline" means the shop stops taking orders from step 1 until the target is validated in step 5: that window is
# the downtime, and the script measures it. An online migration (logical replication) keeps the source writable while
# it copies, and the downtime shrinks to the final switch-over.
#
# Run it again whenever you like: it recreates the target database and copies the source as it is now.

# Run Command may start the script with /bin/sh; everything below is bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

target_host=${1:?usage: migrate-database.sh <server>.postgres.database.azure.com [role name]}
# The managed identity's role on the target is named after the VM (the administrator that migration.bicep adds).
target_user=${2:-$(hostname)}
db=legacyshop
dump=/var/tmp/$db.dump

started=$(date +%s)
log() { printf '%5ss  %s\n' $(($(date +%s) - started)) "$*"; }
# The source: the local socket with peer authentication, as the "postgres" operating-system user. No password.
source_sql() { sudo -u postgres psql -qAtX -v ON_ERROR_STOP=1 "$@"; }

log "Source: $(source_sql -d $db -c "SELECT pg_size_pretty(pg_database_size('$db'))"), \
$(source_sql -d $db -c 'SELECT count(*) FROM shop.orders') orders, \
newest $(source_sql -d $db -c 'SELECT max(order_date)::timestamp(0) FROM shop.orders')"

# 1. The downtime starts: no more writes. From the "postgres" database, because a read-only database can't change
#    its own settings. The shop's cron job fails from now on (journalctl -t legacy-shop).
source_sql -d postgres -c "ALTER DATABASE $db SET default_transaction_read_only = on"
source_sql -d postgres -c "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
                           WHERE datname = '$db' AND pid <> pg_backend_pid()" >/dev/null
frozen=$(date +%s)
log "Source is read-only: the shop is closed"

# 2. Dump the whole database: custom format, compressed, and restorable in parallel. No owners and no grants: the
#    target has its own roles.
sudo -u postgres pg_dump -d $db -Fc --no-owner --no-acl -f $dump
log "Dumped $(du -h $dump | cut -f1) to $dump"

# 3. The target's "password" is a token for this server's managed identity, from the instance metadata service.
#    It expires after about an hour, and nothing stores it.
PGPASSWORD=$(curl -sSf -H Metadata:true \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fossrdbms-aad.database.windows.net" |
  jq -r .access_token)
export PGPASSWORD PGHOST=$target_host PGUSER=$target_user PGSSLMODE=require
target_sql() { psql -qAtX -v ON_ERROR_STOP=1 "$@"; }

# 4. Restore into a fresh database. pg_restore --create would copy the source's locale, which the target may not
#    have, so the database is created here with the server's defaults. Two parallel jobs, one per vCore.
target_sql -d postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db"
pg_restore -d $db --no-owner --no-acl --exit-on-error -j 2 $dump
# The migration identity owns what it restored. Let the server's other administrators (you) read it.
target_sql -d $db -c "GRANT USAGE ON SCHEMA shop TO azure_pg_admin" \
  -c "GRANT SELECT ON ALL TABLES IN SCHEMA shop TO azure_pg_admin"
log "Restored into $db on $target_host"

# 5. Validate: the same row counts and money on both sides, or the migration isn't done.
check="SELECT 'customers', count(*), 0 FROM shop.customers
       UNION ALL SELECT 'orders', count(*), sum(total) FROM shop.orders
       UNION ALL SELECT 'order_items', count(*), sum(qty * unit_price) FROM shop.order_items
       ORDER BY 1"
on_source=$(source_sql -d $db -c "$check")
on_target=$(target_sql -d $db -c "$check")
echo "table|source rows|source amount|target rows|target amount"
paste -d '|' <(echo "$on_source") <(echo "$on_target" | cut -d '|' -f 2-)

if [[ $on_source != "$on_target" ]]; then
  log "MISMATCH: the target doesn't match the source. The source stays read-only; investigate before reopening."
  exit 1
fi
log "Validated. Downtime so far: $(($(date +%s) - frozen)) s. Now point the applications at the target."
