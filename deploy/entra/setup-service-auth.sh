#!/usr/bin/env bash
# Phase 16: service-to-service authentication for the Payments and Shipping APIs, with no secrets anywhere.
#
#   1. An app registration per service that defines an *application* app role (Payments.Process / Shipments.Manage).
#   2. Those roles assigned to the callers' managed identities: the Functions app (runs the saga) and the API (runs
#      it in-process while messaging is off). Managed identities can only get app roles through Microsoft Graph,
#      not the portal, hence this script.
#
# Run in Azure Cloud Shell (bash) or Git Bash, signed in as someone who can create app registrations, after the
# first deployment with deployPayments / deployShipping = true:
#
#   ./deploy/entra/setup-service-auth.sh rg-cloudmart-dev
#
# Then put the two client ids it prints into infra/main.bicepparam (entraPaymentsClientId, entraShippingClientId),
# make sure enableEntraAuth = true, and redeploy. Safe to run again: it reuses what already exists.
set -euo pipefail

rg="${1:?usage: $0 <resource-group>}"
graph="https://graph.microsoft.com/v1.0"

identity_principal() { az identity list -g "$rg" --query "[?ends_with(name, '-$1')].principalId | [0]" -o tsv; }

# Creates (or finds) an app registration exposing one application role, and returns "<appId> <roleId>".
ensure_api() {
  local name="$1" role="$2" description="$3"
  local app_id
  app_id=$(az ad app list --display-name "$name" --query "[0].appId" -o tsv)
  if [ -z "$app_id" ]; then
    app_id=$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)
  fi

  local role_id
  role_id=$(az ad app show --id "$app_id" --query "appRoles[?value=='$role'].id | [0]" -o tsv)
  if [ -z "$role_id" ]; then
    role_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || powershell.exe -NoProfile -Command "[guid]::NewGuid()" | tr -d '\r')
    # allowedMemberTypes Application = an app role for daemons and services, not for users or groups.
    az ad app update --id "$app_id" --app-roles "[{
      \"allowedMemberTypes\": [\"Application\"],
      \"description\": \"$description\",
      \"displayName\": \"$role\",
      \"id\": \"$role_id\",
      \"isEnabled\": true,
      \"value\": \"$role\"
    }]"
  fi

  # The audience callers ask for: api://<appId>. Tokens for it carry "aud": "api://<appId>".
  az ad app update --id "$app_id" --identifier-uris "api://$app_id"
  az ad sp show --id "$app_id" >/dev/null 2>&1 || az ad sp create --id "$app_id" >/dev/null
  echo "$app_id $role_id"
}

# Assigns an app role to a managed identity's service principal (idempotent).
grant() {
  local caller="$1" app_id="$2" role_id="$3" label="$4"
  local resource_sp
  resource_sp=$(az ad sp show --id "$app_id" --query id -o tsv)
  if az rest --method GET --uri "$graph/servicePrincipals/$caller/appRoleAssignments" \
      --query "value[?appRoleId=='$role_id' && resourceId=='$resource_sp'] | [0].id" -o tsv | grep -q .; then
    echo "  $label: already assigned"
    return
  fi
  az rest --method POST --uri "$graph/servicePrincipals/$caller/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\": \"$caller\", \"resourceId\": \"$resource_sp\", \"appRoleId\": \"$role_id\"}" >/dev/null
  echo "  $label: assigned"
}

functions_sp=$(identity_principal func)
api_sp=$(identity_principal api)
[ -n "$functions_sp" ] && [ -n "$api_sp" ] || { echo "Managed identities not found in $rg. Deploy first." >&2; exit 1; }

read -r payments_app payments_role < <(ensure_api "CloudMart Payments" "Payments.Process" "Charge and refund payments")
read -r shipping_app shipping_role < <(ensure_api "CloudMart Shipping" "Shipments.Manage" "Schedule and cancel shipments")

echo "Granting app roles to the managed identities:"
grant "$functions_sp" "$payments_app" "$payments_role" "Functions -> Payments.Process"
grant "$api_sp" "$payments_app" "$payments_role" "API -> Payments.Process"
grant "$functions_sp" "$shipping_app" "$shipping_role" "Functions -> Shipments.Manage"
grant "$api_sp" "$shipping_app" "$shipping_role" "API -> Shipments.Manage"

cat <<EOF

Put these in infra/main.bicepparam, then redeploy:
  param entraPaymentsClientId = '$payments_app'
  param entraShippingClientId = '$shipping_app'

Managed identity tokens are cached for up to 24 hours, so a role granted now can take a while to show up in a
running app's token. Restart the Functions app and the API to pick it up straight away.
EOF
