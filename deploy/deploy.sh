#!/usr/bin/env bash
# One-shot deploy to Azure Container Apps. Run from Git Bash / WSL / macOS / Linux:
#   az login
#   bash deploy/deploy.sh
#
# Optional overrides:  RG=rg-stockmarket LOCATION=centralindia TAG=v1 bash deploy/deploy.sh
set -euo pipefail

RG="${RG:-rg-stockmarket}"
LOCATION="${LOCATION:-centralindia}"
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYFILE="$ROOT/backend/key.txt"

[ -f "$KEYFILE" ] || { echo "backend/key.txt not found (needed once, to load the secrets into Key Vault)"; exit 1; }
az account show >/dev/null 2>&1 || { echo "Run 'az login' first"; exit 1; }
echo "Subscription: $(az account show --query name -o tsv)"
echo "Resource group: $RG ($LOCATION)   image tag: $TAG"
read -r -p "Continue? [y/N] " ok; [[ "$ok" =~ ^[Yy]$ ]] || exit 0

# A Key Vault deleted in the last 7 days keeps its name reserved; the same name would be reused by this template.
DELETED=$(az keyvault list-deleted --query "[?starts_with(name,'kv-stockmkt-')].name" -o tsv 2>/dev/null | tr -d '\r' || true)
if [ -n "$DELETED" ]; then
  echo "Found a soft-deleted Key Vault from a previous deploy: $DELETED"
  read -r -p "Purge it so the name can be reused? (its old secrets are erased; they are re-loaded from key.txt) [y/N] " pg
  if [[ "$pg" =~ ^[Yy]$ ]]; then
    for v in $DELETED; do az keyvault purge --name "$v" --location "$LOCATION" -o none; done
  else
    echo "Not purged: the deploy will fail on the Key Vault name. Re-run after purging."; exit 1
  fi
fi

echo "==> 1/5 Resource group + foundation (registry, Key Vault, identity, environment)"
az group create -n "$RG" -l "$LOCATION" -o none
OUT=$(az deployment group create -g "$RG" -f "$ROOT/deploy/main.bicep" \
      -p deployApps=false --query properties.outputs -o json)
ACR=$(echo "$OUT" | python -c "import sys,json; print(json.load(sys.stdin)['acrName']['value'])")
KV=$(echo "$OUT"  | python -c "import sys,json; print(json.load(sys.stdin)['keyVaultName']['value'])")
echo "    registry: $ACR   key vault: $KV"

echo "==> 2/5 Store secrets in Key Vault (values are not printed)"
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

echo "==> 3/5 Build + push images with ACR Tasks (no local Docker needed; .dockerignore keeps key.txt out)"
az acr build -r "$ACR" -t "stockmarket-backend:$TAG"  "$ROOT/backend"
az acr build -r "$ACR" -t "stockmarket-frontend:$TAG" "$ROOT/frontend"

echo "==> 4/5 Create the container apps"
OUT=$(az deployment group create -g "$RG" -f "$ROOT/deploy/main.bicep" \
      -p deployApps=true imageTag="$TAG" --query properties.outputs -o json)
URL=$(echo "$OUT" | python -c "import sys,json; print(json.load(sys.stdin)['frontendUrl']['value'])")

echo "==> 5/5 Done"
echo "    Frontend (public): $URL"
echo "    Backend has internal ingress only; it is not reachable from the internet."
