# GitHub + Azure setup for dev / qa / uat / prod

This is the one-time setup that turns the repository into a pipeline: **merge to `main` → build once → dev → qa →
(approval) uat → (approval) prod.** After it's done you never run a deploy by hand again.

> **Status:** the Bicep templates, parameter files, Dockerfiles and workflow files are validated locally (templates
> compile, images build and run, workflow files parse and cross-reference correctly). **Nothing here has been run against
> your real Azure tenant or GitHub repo yet**, so do the steps in order and follow the checks at the end. Start with
> `dev` only if you want to be careful, then add the others.

## 1. How it fits together

```
 pull request ──▶ ci.yml        compiles Bicep, builds both images (no Azure access needed)

 merge to main ─▶ pipeline.yml
                    build ──▶ dev ──▶ qa ──▶ uat ──▶ prod
                    (push the     auto    auto   waits for   waits for
                     images once,                approval    approval
                     tag = commit SHA)
                    each "deploy" job = deploy-env.yml: azure login (OIDC) → deploy Bicep → smoke test
```

| Piece | Where it lives |
|---|---|
| Shared container registry (one, all environments) | `rg-stockmarket-shared` |
| Everything else, per environment | `rg-stockmarket-dev`, `-qa`, `-uat`, `-prod` (own Key Vault, identity, Container Apps environment, log workspace, two apps) |
| Per-environment size/scale | `deploy/params/<env>.bicepparam` |
| Azure login from GitHub | One Entra app registration per environment with a **federated credential**. No passwords or secrets in GitHub. |
| Groww secrets | In each environment's **Key Vault** (never in GitHub) |

Two kinds of deployer, on purpose:
- **You (Owner) via `deploy/deploy.sh <env>`:** the *first* deploy of an environment. It creates the role assignments and,
  for prod, the delete-lock. Needs high rights, so it stays on your machine.
- **The pipeline (Contributor on one resource group only):** day-to-day updates. It runs with `MANAGE_RBAC=false`, so it
  never needs permission to grant roles. A leaked pipeline identity can't hand out access or read secrets.

## 2. Before you start

- Azure CLI installed and `az login` done, with **Owner** on the subscription (or Contributor + User Access Administrator).
- Permission to create app registrations in your Entra tenant.
- **Admin rights on the GitHub repo.** The repo is public, so environment approvals are available for free. If you ever
  make it private, required reviewers need a paid GitHub plan.
- **Git Bash, WSL, macOS or Linux** for the shell snippets below (PowerShell quoting differs). In Git Bash the snippets
  need `export MSYS_NO_PATHCONV=1` (already included; `deploy.sh` sets it itself).
- Don't paste `<angle-bracket placeholders>` literally: bash reads `<...>` as a redirect and fails with
  "syntax error near unexpected token `newline'".
- `backend/key.txt` filled in (used once to load the secrets into Key Vault).

## 3. Step 1: bootstrap each environment in Azure (one-time, from your machine)

```bash
az login
bash deploy/deploy.sh dev
bash deploy/deploy.sh qa
bash deploy/deploy.sh uat
bash deploy/deploy.sh prod      # asks you to type "prod" to confirm
```

Each run (it's safe to re-run):
1. creates `rg-stockmarket-shared` and the shared registry (first time only),
2. creates `rg-stockmarket-<env>` with its Key Vault, identity, Container Apps environment and role assignments,
3. offers to load the Groww secrets from `backend/key.txt` into that environment's Key Vault,
4. builds and pushes the images, and
5. creates the two container apps and prints the public URL.

**Write down the registry name** printed at the end (`ACR_NAME=acrstockmkt…`). You need it in step 3.

Tips:
- You can skip environments you don't need yet. The pipeline fails clearly for an environment whose resource group
  doesn't exist.
- For **prod**, answer **n** to the secrets prompt if someone else owns the production credentials, and have them run:
  `az keyvault secret set --vault-name <prod-vault> -n groww-totp-token --value "<token>"` (and `groww-totp-secret`).
  They need the *Key Vault Secrets Officer* role on that vault.
- Creating the prod resource group adds a `CanNotDelete` lock. See "Tearing down prod" below.

## 4. Step 2: let GitHub log in to Azure (one identity per environment)

Two short blocks. Both are **safe to re-run** and contain **nothing you need to edit** (no `<placeholders>`).

> **Git Bash on Windows:** the first line, `export MSYS_NO_PATHCONV=1`, is required. Without it Git Bash rewrites
> `/subscriptions/...` into a Windows path and Azure answers `MissingSubscription`.

**A. Create the identities and their GitHub trust** (one Entra app registration per environment, each trusted *only* for
the matching GitHub Environment). List only the environments you want. If an identity already exists, this **updates its
trust in place**.

```bash
export MSYS_NO_PATHCONV=1
REPO=hozefam/StockMarketAnalysis
ENVS="dev qa uat prod"

# GitHub puts numeric IDs into the login subject, e.g. repo:owner@123/name@456:environment:dev
# (it protects against someone re-using a deleted repo's name). Ask GitHub's public API for the exact form:
IDS=$(curl -s "https://api.github.com/repos/$REPO" | python -c "import sys,json; d=json.load(sys.stdin); print('%s@%s/%s@%s' % (d['owner']['login'], d['owner']['id'], d['name'], d['id']))")
echo "repo identity used in the subjects: $IDS"

for ENV in $ENVS; do
  APP_ID=$(az ad app list --display-name "sp-stockmarket-$ENV" --query "[0].appId" -o tsv)
  if [ -z "$APP_ID" ]; then
    APP_ID=$(az ad app create --display-name "sp-stockmarket-$ENV" --query appId -o tsv)
    az ad sp create --id "$APP_ID" > /dev/null
  fi
  # "only a workflow job running in the GitHub Environment named $ENV of this repo may log in as this identity"
  CRED="{
    \"name\": \"github-$ENV\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:$IDS:environment:$ENV\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
  if az ad app federated-credential show --id "$APP_ID" --federated-credential-id "github-$ENV" > /dev/null 2>&1; then
    az ad app federated-credential update --id "$APP_ID" --federated-credential-id "github-$ENV" --parameters "$CRED" > /dev/null
  else
    az ad app federated-credential create --id "$APP_ID" --parameters "$CRED" > /dev/null
  fi
  echo "$ENV  AZURE_CLIENT_ID=$APP_ID   trusts: repo:$IDS:environment:$ENV"
done
echo "AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)"
echo "AZURE_SUBSCRIPTION_ID=$(az account show --query id -o tsv)"
```

Keep the printed values for step 3 (none of them is a secret).

> **If a login still fails with `AADSTS700213` / `AADSTS70021`,** open the failed step's log: it prints the exact
> `subject claim` GitHub sent. The credential's subject must match that text character for character. Set it with
> `az ad app federated-credential update` using the string from the log.

**B. Give each identity its rights** (least privilege). Run this **after** an environment has been bootstrapped in step 1;
environments that don't exist yet are skipped, so just run it again later.

```bash
export MSYS_NO_PATHCONV=1
SUB=$(az account show --query id -o tsv)
ENVS="dev qa uat prod"

for ENV in $ENVS; do
  APP_ID=$(az ad app list --display-name "sp-stockmarket-$ENV" --query "[0].appId" -o tsv)
  if az group show -n "rg-stockmarket-$ENV" > /dev/null 2>&1; then
    # Contributor on this environment's resource group only
    az role assignment create --assignee "$APP_ID" --role Contributor \
       --scope "/subscriptions/$SUB/resourceGroups/rg-stockmarket-$ENV" -o none \
       && echo "$ENV: Contributor granted"
  else
    echo "$ENV: skipped (rg-stockmarket-$ENV does not exist yet; bootstrap it, then re-run this block)"
  fi
done

# Only the dev identity pushes images (the build job runs in the dev environment):
ACR=$(az acr list -g rg-stockmarket-shared --query "[0].name" -o tsv)
DEV_APP_ID=$(az ad app list --display-name "sp-stockmarket-dev" --query "[0].appId" -o tsv)
az role assignment create --assignee "$DEV_APP_ID" --role AcrPush \
   --scope "$(az acr show -n "$ACR" --query id -o tsv)" -o none && echo "dev: AcrPush granted on $ACR"
echo "ACR_NAME=$ACR"
```

Notes:
- "The role assignment already exists" on a re-run is fine.
- "Cannot find service principal" right after creating one means Azure hasn't caught up yet. Wait a minute and re-run.
- Check what an identity holds: `az role assignment list --assignee <client id> --all -o table`.

Why this is safe: the federated credential has no password to steal, and it only works for jobs that GitHub itself runs
inside the named Environment, so approval rules and branch restrictions on `prod` also protect the Azure login. The
pipeline identity is Contributor on one resource group; it cannot grant roles or read Key Vault secrets.

## 5. Step 3: configure GitHub (web UI)

Repo → **Settings**.

### 5.1 Environments (Settings → Environments → New environment)
Create **`dev`**, **`qa`**, **`uat`**, **`prod`**. The names must match exactly (they're in the federated credential).

For **each** environment, add these *Environment variables* (not secrets):

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | that environment's client ID from step 2 (different for each) |
| `AZURE_TENANT_ID` | the tenant ID (same everywhere) |
| `AZURE_SUBSCRIPTION_ID` | the subscription ID (same everywhere) |

Protection rules:

| Environment | Rule |
|---|---|
| `dev` | none |
| `qa` | none (it follows dev automatically). Optionally add a wait timer. |
| `uat` | **Required reviewers**: add yourself and/or your team |
| `prod` | **Required reviewers** + **Deployment branches and tags → Selected branches → `main`** |

If you work alone, leave **Prevent self-review** *off*, or you won't be able to approve your own deployments.

### 5.2 Repository variable (Settings → Secrets and variables → Actions → Variables)

| Variable | Value |
|---|---|
| `ACR_NAME` | the registry name from step 1 |
| `SHARED_RG` | *(optional)* only if you used a different shared resource group name |

You don't need any GitHub **secrets** at all. Azure login is passwordless.

### 5.3 Branch protection for `main` (Settings → Branches → Add branch ruleset)
- Require a pull request before merging.
- Require status checks to pass: **`bicep`**, **`docker (backend)`**, **`docker (frontend)`**.
  (They only appear in the picker after they've run once. Open a throwaway pull request first.)
- Block force pushes and deletions.
- Optional: *Do not allow bypassing* so the rules apply to you too.

### 5.4 Optional: the same thing from the command line
The web UI above is the reference. If you install the GitHub CLI (`gh auth login`), the variables can be set like this:

```bash
gh variable set ACR_NAME --repo "$REPO" --body "$ACR"
for ENV in dev qa uat prod; do
  gh api -X PUT "repos/$REPO/environments/$ENV" > /dev/null
  gh variable set AZURE_TENANT_ID       --repo "$REPO" --env "$ENV" --body "$TENANT"
  gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env "$ENV" --body "$SUB"
done
# AZURE_CLIENT_ID differs per environment:
gh variable set AZURE_CLIENT_ID --repo "$REPO" --env dev --body "<dev client id>"   # repeat for qa, uat, prod
```
Reviewers and branch restrictions are easier in the web UI.

## 6. Day-to-day

**Normal change**
1. Open a pull request. `ci` runs (compiles Bicep, builds images).
2. Merge it. `pipeline` builds the images once, tags them with the commit SHA, deploys **dev**, then **qa**.
3. When the run reaches **uat** and **prod** it pauses. Open the run in the **Actions** tab → **Review deployments** →
   tick the environment → **Approve**.

**Deploy or roll back a specific version**
Actions → **pipeline** → **Run workflow** → pick the environment and paste an image tag (the commit SHA of an earlier
successful build). Nothing is rebuilt; that exact image is deployed.

**Things to know**
- Two merges close together start two runs. Environments are deployed one at a time, but the older run could reach
  uat/prod approval after the newer one. Approve the newest and reject the older.
- The smoke test calls `/` and `/api/groww/status`. Apps scale to zero, so the first call retries for up to a minute.
- If the Groww API is down, `/api/groww/status` still answers (`connected: false`) and the smoke test passes. It checks
  that the frontend, gateway and backend are wired up, not that Groww is healthy.

## 7. Where configuration and secrets live

| What | Where | Who changes it |
|---|---|---|
| Groww token and secret | Key Vault of that environment | A person with *Key Vault Secrets Officer* |
| Scaling and size | `deploy/params/<env>.bicepparam` | Pull request |
| Azure IDs (not secret) | GitHub Environment variables | Repo admin |
| Which image is running | The pipeline (commit SHA) | The pipeline, or a manual run |
| Roles, prod lock | `deploy/deploy.sh <env>` | You, with Owner rights |

To rotate a Groww secret: set the new value in that environment's Key Vault, then restart the backend so it picks it up:
`az containerapp revision restart -g rg-stockmarket-<env> -n ca-backend --revision <name from az containerapp revision list>`
(or just run the pipeline for that environment again).

## 8. Cost

| | Approx. per month |
|---|---|
| dev, qa, uat (scale to zero, 0.25 vCPU / 0.5 GiB) | about $0 each. Inside the free Container Apps allowance, which is shared by the whole subscription. |
| prod (1 frontend + 1 backend replica always on) | about $10 |
| Shared registry (Basic) | about $5 |
| Key Vaults, log workspaces, identities | about $0 |
| **Total** | **about $15** |

Notes:
- Prices are Azure retail rates for Central India at light traffic.
- Azure deletes a Container Apps environment that has been idle for more than 90 days. dev, qa and uat scale to zero, so
  if you leave them untouched for months they may disappear. Run `bash deploy/deploy.sh <env>` to recreate one. prod
  is always warm, so it's safe.

## 9. Hardening to do before real use

- **Put a login in front of prod (and ideally every environment).** The app shows your Groww margin and holdings. On
  `ca-frontend`, enable Container Apps authentication with Microsoft Entra ID. Afterwards the smoke test's
  `curl --fail` will get redirected to a login page. Exclude `/api/env` from authentication and point the smoke test
  there instead.
- For real redundancy in prod, set both min replicas to 2 in `prod.bicepparam` (about $10 more).
- Add Azure Monitor alerts on prod for failed requests and restarts.
- Add a custom domain with a managed certificate when you have one.

## 10. Tearing down

```bash
az group delete -n rg-stockmarket-dev --yes --no-wait        # same for qa and uat
```

**Prod is locked on purpose.** To delete it, remove the lock first:
```bash
az lock delete --name lock-prod-no-delete -g rg-stockmarket-prod
az group delete -n rg-stockmarket-prod --yes --no-wait
```
Prod's Key Vault has **purge protection**, so after deletion it stays recoverable (and keeps its name) for 30 days and
cannot be purged early. To redeploy prod within that window, recover it first:
`az keyvault recover --name <prod vault name>` and then run `bash deploy/deploy.sh prod`.

Delete `rg-stockmarket-shared` **last**, since running apps pull their images from the registry in it.
dev/qa/uat vaults are soft-deleted for 7 days; `deploy.sh` offers to purge them when you redeploy.

## 11. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `MissingSubscription` from `az role assignment create` (Git Bash) | Git Bash rewrote the `/subscriptions/...` scope into a Windows path. Run `export MSYS_NO_PATHCONV=1` first, then re-run the command. |
| `syntax error near unexpected token 'newline'` | A `<placeholder>` was pasted literally. Replace it with a real value (the step 2 blocks no longer have any). |
| `usage error: --assignee can't be an empty string` | A variable is empty, usually because the line that sets it failed earlier. Fix that line first. |
| `AADSTS700213` / `AADSTS70021: No matching federated identity record found` | The credential's `subject` doesn't match what GitHub sent. The failed log shows the exact `subject claim`; it includes numeric IDs for this repo (`repo:hozefam@<owner id>/StockMarketAnalysis@<repo id>:environment:dev`). Re-run block A in step 2, which sets it correctly, or paste the logged subject into `az ad app federated-credential update`. Also check the environment name is lowercase and exact. |
| `AuthorizationFailed` on the deploy step | The environment's identity lacks **Contributor** on `rg-stockmarket-<env>`. Role assignments can take a few minutes to take effect. |
| `Resource group rg-stockmarket-<env> does not exist` | That environment was never bootstrapped. Run `bash deploy/deploy.sh <env>`. |
| `AuthorizationFailed … roleAssignments/write` | Something is deploying with `MANAGE_RBAC=true` without Owner rights. The pipeline must keep it `false`. |
| `docker push` denied in the build job | The dev identity is missing **AcrPush** on the registry, or `ACR_NAME` is wrong. |
| App stuck on `ImagePullBackOff` | The environment's identity doesn't have **AcrPull** on the registry. Re-run `bash deploy/deploy.sh <env>` (it re-applies the role). |
| Backend crashes at start / `KeyError` for the secret | The Groww secrets aren't in that environment's Key Vault yet (see section 3). |
| Key Vault name conflict on deploy | An old vault of that name is soft-deleted. `deploy.sh` offers to purge it (for prod, use `az keyvault recover` instead). |
| Variables look empty in a job | They are set on the wrong scope. `AZURE_*` are *Environment* variables; `ACR_NAME` is a *repository* variable. |
| Smoke test fails right after a deploy | Cold start. Re-run the job. If it persists, check the app's logs in the Azure portal. |

## 12. What was added to the repository

| Path | Purpose |
|---|---|
| `deploy/shared.bicep` | the shared registry |
| `deploy/main.bicep` | one environment (parameterised by `environmentName`) |
| `deploy/acr-pull.bicep` | lets an environment's identity pull from the shared registry |
| `deploy/params/dev, qa, uat, prod.bicepparam` | per-environment size and scale |
| `deploy/deploy.sh <env>` | one-time bootstrap / manual deploy of an environment |
| `.github/workflows/ci.yml` | pull-request checks |
| `.github/workflows/pipeline.yml` | build once, promote dev → qa → uat → prod |
| `.github/workflows/deploy-env.yml` | reusable deploy + smoke test for one environment |
| `frontend/app/EnvBadge.js`, `frontend/app/api/env/route.js` | corner label ("DEV", "QA", "UAT") on non-prod environments |
