#!/usr/bin/env bash
# Phase 8: one-time Azure setup for weather-service (Azure Container Apps, Consumption plan).
#
# Creates: resource group, Log Analytics (with daily cap), Container Apps environment,
# Entra app registration + JobExecute role, job managed identity + role assignment,
# Container App (API), Container Apps Job (scheduled), GitHub OIDC login, budget alert.
#
# Safe to re-run: existing resources are reused, not duplicated.
#
# Usage:
#   export WEATHERAPI_KEY=...      # from weatherapi.com
#   export API_KEY=...             # any long random string; callers send it as X-Api-Key
#   export BUDGET_EMAIL=...        # where budget alerts go
#   ./infra/setup.sh
#
# Requires: az (logged in), gh (logged in), jq
set -euo pipefail

# ── Settings ───────────────────────────────────────────────────────────────
LOCATION="centralus"
RG="rg-weather-service"
LAW="log-weather-service"
ENV_NAME="cae-weather-service"
API_APP="ca-weather-api"
JOB="caj-weather-daily"
JOB_IDENTITY="id-weather-job"
API_AAD_APP="weather-api"
GH_AAD_APP="weather-service-github"
GH_REPO="lishamsingh/weather-service"
GH_ENVIRONMENT="production"
API_IMAGE="ghcr.io/lishamsingh/weather-api:latest"
JOB_IMAGE="ghcr.io/lishamsingh/weather-job:latest"
WEATHER_ZIP="10001"
BUDGET_AMOUNT=1
CRON="0 12,13 * * 1-5"   # UTC; the job itself only proceeds at 7 AM America/Chicago

: "${WEATHERAPI_KEY:?Set WEATHERAPI_KEY}"
: "${API_KEY:?Set API_KEY}"
: "${BUDGET_EMAIL:?Set BUDGET_EMAIL}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
log "Subscription $(az account show --query name -o tsv) ($SUBSCRIPTION_ID)"

# ── 1. Providers and CLI extension ─────────────────────────────────────────
log "Registering resource providers"
az extension add --name containerapp --upgrade --only-show-errors
for ns in Microsoft.App Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
  az provider register --namespace "$ns" --wait --only-show-errors
done

# ── 2. Resource group ──────────────────────────────────────────────────────
log "Resource group $RG"
az group create -n "$RG" -l "$LOCATION" -o none

# ── 3. Log Analytics (0.1 GB/day cap keeps it inside the free 5 GB/month) ──
log "Log Analytics workspace $LAW"
az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION" \
  --retention-time 30 --quota 0.1 -o none
LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
LAW_KEY=$(az monitor log-analytics workspace get-shared-keys -g "$RG" -n "$LAW" --query primarySharedKey -o tsv)

# ── 4. Container Apps environment ──────────────────────────────────────────
log "Container Apps environment $ENV_NAME"
if ! az containerapp env show -g "$RG" -n "$ENV_NAME" -o none 2>/dev/null; then
  az containerapp env create -g "$RG" -n "$ENV_NAME" -l "$LOCATION" \
    --logs-workspace-id "$LAW_ID" --logs-workspace-key "$LAW_KEY" -o none
fi

# ── 5. Entra app registration for the API, with the JobExecute app role ────
log "Entra app registration $API_AAD_APP"
API_APP_ID=$(az ad app list --display-name "$API_AAD_APP" --query "[0].appId" -o tsv)
if [[ -z "$API_APP_ID" ]]; then
  ROLE_ID=$(uuidgen | tr 'A-Z' 'a-z')
  ROLES_FILE=$(mktemp)
  cat > "$ROLES_FILE" <<EOF
[{
  "allowedMemberTypes": ["Application"],
  "description": "Allows the scheduled job to call POST /api/weather/scheduled",
  "displayName": "JobExecute",
  "id": "$ROLE_ID",
  "isEnabled": true,
  "value": "JobExecute"
}]
EOF
  API_APP_ID=$(az ad app create --display-name "$API_AAD_APP" \
    --sign-in-audience AzureADMyOrg --app-roles @"$ROLES_FILE" --query appId -o tsv)
  rm -f "$ROLES_FILE"
  az ad app update --id "$API_APP_ID" --identifier-uris "api://$API_APP_ID"
fi
ROLE_ID=$(az ad app show --id "$API_APP_ID" --query "appRoles[?value=='JobExecute'].id | [0]" -o tsv)
API_SP_ID=$(az ad sp show --id "$API_APP_ID" --query id -o tsv 2>/dev/null \
  || az ad sp create --id "$API_APP_ID" --query id -o tsv)

# ── 6. Managed identity for the job, granted JobExecute ────────────────────
log "Managed identity $JOB_IDENTITY"
az identity create -g "$RG" -n "$JOB_IDENTITY" -l "$LOCATION" -o none
MI_RESOURCE_ID=$(az identity show -g "$RG" -n "$JOB_IDENTITY" --query id -o tsv)
MI_CLIENT_ID=$(az identity show -g "$RG" -n "$JOB_IDENTITY" --query clientId -o tsv)
MI_PRINCIPAL_ID=$(az identity show -g "$RG" -n "$JOB_IDENTITY" --query principalId -o tsv)

log "Assigning JobExecute to the job identity"
EXISTING=$(az rest --method GET \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$MI_PRINCIPAL_ID/appRoleAssignments" \
  --query "value[?appRoleId=='$ROLE_ID'] | length(@)" -o tsv 2>/dev/null || echo 0)
if [[ "$EXISTING" == "0" ]]; then
  # A brand-new identity can take a moment to appear in Entra
  for i in 1 2 3 4 5 6; do
    if az rest --method POST \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$MI_PRINCIPAL_ID/appRoleAssignments" \
      --headers "Content-Type=application/json" \
      --body "{\"principalId\":\"$MI_PRINCIPAL_ID\",\"resourceId\":\"$API_SP_ID\",\"appRoleId\":\"$ROLE_ID\"}" \
      -o none 2>/dev/null; then break; fi
    [[ $i == 6 ]] && { echo "Role assignment failed"; exit 1; }
    echo "  identity not visible in Entra yet, retrying in 10s..."; sleep 10
  done
fi

# ── 7. API Container App ───────────────────────────────────────────────────
log "Container App $API_APP"
API_ENV_VARS=(
  "WeatherApi__Key=secretref:weatherapi-key"
  "ApiKey=secretref:api-key"
  "WeatherApi__ZipCode=$WEATHER_ZIP"
  "AzureAd__TenantId=$TENANT_ID"
  "AzureAd__ClientId=$API_APP_ID"
)
if ! az containerapp show -g "$RG" -n "$API_APP" -o none 2>/dev/null; then
  az containerapp create -g "$RG" -n "$API_APP" --environment "$ENV_NAME" \
    --image "$API_IMAGE" --ingress external --target-port 8080 \
    --min-replicas 0 --max-replicas 1 --cpu 0.25 --memory 0.5Gi \
    --secrets "weatherapi-key=$WEATHERAPI_KEY" "api-key=$API_KEY" \
    --env-vars "${API_ENV_VARS[@]}" -o none
else
  az containerapp secret set -g "$RG" -n "$API_APP" \
    --secrets "weatherapi-key=$WEATHERAPI_KEY" "api-key=$API_KEY" -o none
  az containerapp update -g "$RG" -n "$API_APP" --set-env-vars "${API_ENV_VARS[@]}" -o none
fi
API_FQDN=$(az containerapp show -g "$RG" -n "$API_APP" --query properties.configuration.ingress.fqdn -o tsv)

# ── 8. Scheduled Container Apps Job ────────────────────────────────────────
log "Container Apps Job $JOB"
JOB_ENV_VARS=(
  "WeatherApi__ScheduledUrl=https://$API_FQDN/api/weather/scheduled"
  "AzureAd__Scope=api://$API_APP_ID/.default"
  "AZURE_CLIENT_ID=$MI_CLIENT_ID"   # tells DefaultAzureCredential which identity to use
)
if ! az containerapp job show -g "$RG" -n "$JOB" -o none 2>/dev/null; then
  az containerapp job create -g "$RG" -n "$JOB" --environment "$ENV_NAME" \
    --trigger-type Schedule --cron-expression "$CRON" \
    --replica-timeout 300 --replica-retry-limit 1 \
    --parallelism 1 --replica-completion-count 1 \
    --image "$JOB_IMAGE" --cpu 0.25 --memory 0.5Gi \
    --mi-user-assigned "$MI_RESOURCE_ID" \
    --env-vars "${JOB_ENV_VARS[@]}" -o none
else
  az containerapp job update -g "$RG" -n "$JOB" --set-env-vars "${JOB_ENV_VARS[@]}" -o none
fi

# ── 9. GitHub Actions OIDC login (used by the deploy job in cd.yml) ────────
log "GitHub OIDC app registration $GH_AAD_APP"
GH_APP_ID=$(az ad app list --display-name "$GH_AAD_APP" --query "[0].appId" -o tsv)
if [[ -z "$GH_APP_ID" ]]; then
  GH_APP_ID=$(az ad app create --display-name "$GH_AAD_APP" --query appId -o tsv)
fi
GH_SP_ID=$(az ad sp show --id "$GH_APP_ID" --query id -o tsv 2>/dev/null \
  || az ad sp create --id "$GH_APP_ID" --query id -o tsv)

if [[ -z "$(az ad app federated-credential list --id "$GH_APP_ID" --query "[?name=='github-$GH_ENVIRONMENT'].name" -o tsv)" ]]; then
  az ad app federated-credential create --id "$GH_APP_ID" --parameters "{
    \"name\": \"github-$GH_ENVIRONMENT\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$GH_REPO:environment:$GH_ENVIRONMENT\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" -o none
fi

# Contributor on this resource group only (enough to update the app and job)
az role assignment create --assignee-object-id "$GH_SP_ID" --assignee-principal-type ServicePrincipal \
  --role Contributor --scope "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG" -o none 2>/dev/null || true

log "GitHub environment '$GH_ENVIRONMENT' and secrets"
gh api -X PUT "repos/$GH_REPO/environments/$GH_ENVIRONMENT" --silent
gh secret set AZURE_CLIENT_ID       --repo "$GH_REPO" --env "$GH_ENVIRONMENT" --body "$GH_APP_ID"
gh secret set AZURE_TENANT_ID       --repo "$GH_REPO" --env "$GH_ENVIRONMENT" --body "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID --repo "$GH_REPO" --env "$GH_ENVIRONMENT" --body "$SUBSCRIPTION_ID"

# ── 10. Budget alert ($1/month, emails at 50% / 100% actual and 100% forecast)
log "Budget alert (\$$BUDGET_AMOUNT/month)"
START_DATE="$(date -u +%Y-%m-01)T00:00:00Z"
az rest --method PUT \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Consumption/budgets/budget-weather-service?api-version=2023-05-01" \
  --headers "Content-Type=application/json" \
  --body "{
    \"properties\": {
      \"category\": \"Cost\",
      \"amount\": $BUDGET_AMOUNT,
      \"timeGrain\": \"Monthly\",
      \"timePeriod\": { \"startDate\": \"$START_DATE\" },
      \"notifications\": {
        \"actual50\":    { \"enabled\": true, \"operator\": \"GreaterThan\", \"threshold\": 50,  \"thresholdType\": \"Actual\",     \"contactEmails\": [\"$BUDGET_EMAIL\"] },
        \"actual100\":   { \"enabled\": true, \"operator\": \"GreaterThan\", \"threshold\": 100, \"thresholdType\": \"Actual\",     \"contactEmails\": [\"$BUDGET_EMAIL\"] },
        \"forecast100\": { \"enabled\": true, \"operator\": \"GreaterThan\", \"threshold\": 100, \"thresholdType\": \"Forecasted\", \"contactEmails\": [\"$BUDGET_EMAIL\"] }
      }
    }
  }" -o none

# ── Done ───────────────────────────────────────────────────────────────────
log "Done"
cat <<EOF

API URL:        https://$API_FQDN
Health check:   curl https://$API_FQDN/health
Manual call:    curl -H "X-Api-Key: \$API_KEY" https://$API_FQDN/api/weather/10001
Run job now (bypasses the 7 AM Central check; --env-vars replaces the container's env, so all are listed):
  az containerapp job start -g $RG -n $JOB --container-name $JOB --image $JOB_IMAGE \\
    --env-vars Job__SkipTimeCheck=true ${JOB_ENV_VARS[*]}
Job logs:       az containerapp job execution list -g $RG -n $JOB -o table
EOF
