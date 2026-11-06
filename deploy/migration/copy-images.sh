#!/usr/bin/env bash
# Phase 15, wave 1: copy the legacy shop's product photos into CloudMart with AzCopy. It runs ON the simulated
# on-premises server (where the files are), started from your machine with Run Command:
#
#   az vm run-command invoke -g <legacy resource group> -n <legacy server> --command-id RunShellScript \
#     --scripts @deploy/migration/copy-images.sh \
#     --parameters "https://<storage account>.blob.core.windows.net/product-uploads" full
#
# Modes:
#   dry-run  list what a full copy would send, and send nothing
#   full     copy everything (the bulk copy, days or weeks before the cutover in a real migration)
#   delta    copy only what changed since the last pass started (the catch-up just before the cutover)
#   sync     azcopy sync: compares source and destination. The "break it" in the learning path shows why it is the wrong
#            tool here: the upload pipeline moves each photo out of product-uploads, so sync finds nothing there and
#            copies everything again.
#
# The photos land in product-uploads, not product-images: phase 5's Event Grid pipeline checks each one, publishes
# it and attaches it to its product, exactly as it does for a photo uploaded in Admin. The server's identity can
# write to product-uploads and nowhere else.

# Run Command may start the script with /bin/sh; everything below is bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

target=${1:?usage: copy-images.sh https://<account>.blob.core.windows.net/product-uploads [dry-run|full|delta|sync]}
mode=${2:-full}
source_dir=/srv/legacy-shop/images
state=/var/lib/legacy-shop/last-image-copy # when the previous pass started

# Sign in as this server's managed identity: no account key, no SAS, no password. A real server outside Azure gets
# the same kind of identity from Azure Arc.
export AZCOPY_AUTO_LOGIN_TYPE=MSI
# Run Command starts the script without a home directory, and AzCopy keeps its job plans and logs under it.
export AZCOPY_JOB_PLAN_LOCATION=/var/lib/azcopy/plans AZCOPY_LOG_LOCATION=/var/log/azcopy
mkdir -p "$AZCOPY_JOB_PLAN_LOCATION" "$AZCOPY_LOG_LOCATION" "$(dirname "$state")"

echo "Source: $(find "$source_dir" -type f | wc -l) files, $(du -sh "$source_dir" | cut -f1) in $source_dir"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --output-level essential: only the summary. Run Command returns the last 4 KB of output.
case $mode in
  dry-run)
    azcopy copy "$source_dir/*" "$target" --recursive --dry-run
    exit 0 # nothing was sent, so the next delta still starts from the last real pass
    ;;
  full)
    azcopy copy "$source_dir/*" "$target" --recursive --output-level essential
    ;;
  delta)
    [[ -f $state ]] || { echo "No earlier pass: run full first." >&2; exit 1; }
    since=$(cat "$state")
    echo "Copying files changed since $since"
    azcopy copy "$source_dir/*" "$target" --recursive --include-after "$since" --output-level essential
    ;;
  sync)
    azcopy sync "$source_dir" "$target" --recursive --output-level essential
    ;;
  *)
    echo "Unknown mode '$mode': use dry-run, full, delta or sync." >&2
    exit 1
    ;;
esac

echo "$started" >"$state"
echo "Pass started $started. The next delta copies what changes after that."
