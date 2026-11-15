#!/usr/bin/env bash
# Bootstrap / manual deploy of ONE environment to Azure Container Apps.
# Run from Git Bash / WSL / macOS / Linux, as someone with Owner rights on the subscription:
#
#   az login
#   bash deploy/deploy.sh dev          # or: qa | uat | prod
#
# What it does (safe to re-run):
#   1. shared resource group + the shared container registry (once, reused by every environment)
#   2. this environment's resource group + foundation (Key Vault, identity, Container Apps environment) and role assignments
#   3. optionally loads the Groww secrets into this environment's Key Vault
#   4. builds and pushes both images, tagged with TAG
#   5. creates / updates the container apps
#
# Day-to-day deploys are done by the GitHub pipeline (see GITHUB_SETUP.md); use this script for the FIRST deploy of an
# environment, for emergencies, or if you aren't using GitHub Actions.
#
# Optional overrides:  LOCATION=centralindia TAG=v1 SHARED_RG=rg-stockmarket-shared bash deploy/deploy.sh dev
set -euo pipefail

ENVIRONMENT="${1:-}"
case "$ENVIRONMENT" in dev|qa|uat|prod) ;; *) echo "Usage: bash deploy/deploy.sh <dev|qa|uat|prod>"; exit 1;; esac

RG="rg-stockmarket-$ENVIRONMENT"
SHARED_RG="${SHARED_RG:-rg-stockmarket-shared}"
LOCATION="${LOCATION:-centralindia}"
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYFILE="$ROOT/backend/key.txt"
PARAMS="$ROOT/deploy/params/$ENVIRONMENT.bicepparam"

az account show >/dev/null 2>&1 || { echo "Run 'az login' first"; exit 1; }
echo "Subscription:   $(az account show --query name -o tsv)"
echo "Environment:    $ENVIRONMENT   (resource group $RG, shared registry group $SHARED_RG, $LOCATION)"
echo "Image tag:      $TAG"
read -r -p "Continue? [y/N] " ok; [[ "$ok" =~ ^[Yy]$ ]] || exit 0
if [ "$ENVIRONMENT" = "prod" ]; then
  read -r -p "This is PRODUCTION. Type 'prod' to confirm: " c; [ "$c" = "prod" ] || { echo "Aborted"; exit 1; }
fi

# A Key Vault deleted in the last 7 days keeps its name reserved; this template would reuse that name.
DELETED=$(az keyvault list-deleted --query "[?starts_with(name,'kv-stockmkt-$ENVIRONMENT-')].name" -o tsv 2>/dev/null | tr -d '\r' || true)
if [ -n "$DELETED" ]; then
  echo "Found a soft-deleted Key Vault from a previous deploy: $DELETED"
  read -r -p "Purge it so the name can be reused? (its old secrets are erased) [y/N] " pg
  if [[ "$pg" =~ ^[Yy]$ ]]; then
    for v in $DELETED; do az keyvault purge --name "$v" --location "$LOCATION" -o none; done
  else
    echo "Not purged: the deploy would fail on the Key Vault name. Re-run after purging."; exit 1
  fi
fi

echo "==> 1/5 Shared registry (reused by every environment)"
az group create -n "$SHARED_RG" -l "$LOCATION" -o none
OUT=$(az deployment group create -g "$SHARED_RG" -f "$ROOT/deploy/shared.bicep" --query properties.outputs -o json)
ACR=$(echo "$OUT" | python -c "import sys,json; print(json.load(sys.stdin)['acrName']['value'])")
echo "    registry: $ACR"

echo "==> 2/5 $ENVIRONMENT foundation (Key Vault, identity, Container Apps environment, role assignments)"
az group create -n "$RG" -l "$LOCATION" --tags project=stockmarket environment="$ENVIRONMENT" -o none
OUT=$(DEPLOY_APPS=false MANAGE_RBAC=true IMAGE_TAG="$TAG" SHARED_RG="$SHARED_RG" \
      az deployment group create -g "$RG" -p "$PARAMS" --query properties.outputs -o json)
KV=$(echo "$OUT" | python -c "import sys,json; print(json.load(sys.stdin)['keyVaultName']['value'])")
echo "    key vault: $KV"

echo "==> 3/5 Groww secrets for $ENVIRONMENT"
read -r -p "Load the secrets from backend/key.txt into $KV now? (needed on the first deploy) [y/N] " ls
if [[ "$ls" =~ ^[Yy]$ ]]; then
  [ -f "$KEYFILE" ] || { echo "backend/key.txt not found"; exit 1; }
  ME=$(az ad signed-in-user show --query id -o tsv)
  KVID=$(az keyvault show -n "$KV" --query id -o tsv)
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
     --role "Key Vault Secrets Officer" --scope "$KVID" -o none 2>/dev/null || true
  echo "    waiting for the role assignment to propagate..."; sleep 45
  while IFS='=' read -r k v; do
    v="${v%$'\r'}"
    case "$k" in
      GROWW_TOTP_TOKEN)  az keyvault secret set --vault-name "$KV" -n groww-totp-token  --value "$v" -o none ;;
      GROWW_TOTP_SECRET) az keyvault secret set --vault-name "$KV" -n groww-totp-secret --value "$v" -o none ;;
    esac
  done < "$KEYFILE"
else
  echo "    skipped (set groww-totp-token and groww-totp-secret in $KV yourself before the apps start)"
fi

echo "==> 4/5 Build + push images with ACR Tasks (no local Docker needed; .dockerignore keeps key.txt out)"
az acr build -r "$ACR" -t "stockmarket-backend:$TAG"  "$ROOT/backend"
az acr build -r "$ACR" -t "stockmarket-frontend:$TAG" "$ROOT/frontend"

echo "==> 5/5 Create / update the container apps"
OUT=$(DEPLOY_APPS=true MANAGE_RBAC=true IMAGE_TAG="$TAG" SHARED_RG="$SHARED_RG" \
      az deployment group create -g "$RG" -p "$PARAMS" --query properties.outputs -o json)
URL=$(echo "$OUT" | python -c "import sys,json; print(json.load(sys.stdin)['frontendUrl']['value'])")

echo
echo "Done."
echo "  $ENVIRONMENT frontend (public): $URL"
echo "  Backend has internal ingress only; it is not reachable from the internet."
echo
echo "For the GitHub pipeline (see GITHUB_SETUP.md), set this repository variable:  ACR_NAME=$ACR"
