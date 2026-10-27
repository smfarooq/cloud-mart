-- Phase 4 (PostgreSQL variant): map the managed identities to PostgreSQL roles.
--
-- Your Entra access token is the password:
--   export PGPASSWORD=$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)
--   psql "host=<server>.postgres.database.azure.com dbname=postgres user=<your-upn> sslmode=require" \
--        -f deploy/postgres/grant-managed-identities.sql
--
-- Replace the names with the deployment outputs apiIdentityName and functionsIdentityName.

SELECT * FROM pgaadauth_create_principal('id-cloudmart-dev-api', false, false);
SELECT * FROM pgaadauth_create_principal('id-cloudmart-dev-func', false, false);

\connect cloudmart

-- PostgreSQL 15+ no longer lets everyone create objects in "public". The API creates the schema (EnsureCreated),
-- so it owns the tables; the Functions identity gets data rights on whatever the API creates.
GRANT USAGE, CREATE ON SCHEMA public TO "id-cloudmart-dev-api";
GRANT USAGE ON SCHEMA public TO "id-cloudmart-dev-func";
ALTER DEFAULT PRIVILEGES FOR ROLE "id-cloudmart-dev-api" IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "id-cloudmart-dev-func";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "id-cloudmart-dev-func";
