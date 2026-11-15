# Deploying to Azure Container Apps

Four environments (**dev, qa, uat, prod**) share one container registry. Images are built once and the same image is
promoted through the environments. The one-time GitHub and Azure setup is in **[GITHUB_SETUP.md](GITHUB_SETUP.md)**.

## Architecture (one environment)

```
 Internet ──HTTPS──▶  ca-frontend  (external ingress · built-in load balancer · scale-out)
                          │  server-side proxy: /api/*  →  BACKEND_URL
                          ▼
                      ca-backend   (INTERNAL ingress only)  ──▶  Groww API
                          ▲
   Key Vault ── managed identity ─┘   (GROWW_TOTP_TOKEN / GROWW_TOTP_SECRET injected as env vars)

 Shared Azure Container Registry (rg-stockmarket-shared) ◀── images built once, pulled by each environment's managed identity
```

| Resource group | Contains |
|---|---|
| `rg-stockmarket-shared` | the Container Registry, shared by every environment |
| `rg-stockmarket-dev` / `-qa` / `-uat` / `-prod` | that environment's Key Vault, managed identity, Container Apps environment, log workspace, `ca-frontend`, `ca-backend` |

| Requirement | How it is done |
|---|---|
| Containers | `backend/Dockerfile` (FastAPI) and `frontend/Dockerfile` (Next.js standalone), both non-root. `.dockerignore` keeps `key.txt` out of the images. |
| Azure Container Registry | One shared registry. The pipeline builds and pushes images tagged with the git commit SHA. |
| Azure Container Apps | `deploy/main.bicep` (one environment, selected by `environmentName`) with `deploy/params/<env>.bicepparam`. |
| Frontend as the gateway | The browser only calls the frontend. `frontend/app/api/[...path]/route.js` forwards `/api/*` to the backend server-side, reading `BACKEND_URL` at runtime. |
| Backend callable only from the frontend | Backend ingress is `external: false`: no public endpoint, reachable only from apps in the same environment. |
| Load balancer | The Container Apps ingress load-balances across replicas; each environment sets its own replica range. |
| Secrets in Key Vault | Each environment has its own Key Vault. The backend reads secrets through a managed identity with *Key Vault Secrets User*. No secret is in an image, the Bicep, or GitHub. |

## Environments

| | Replicas (frontend / backend) | Size | Notes |
|---|---|---|---|
| dev | 0–1 / 0–1 | 0.25 vCPU, 0.5 GiB | scales to zero |
| qa | 0–2 / 0–2 | same | scales to zero |
| uat | 0–3 / 0–3 | same | scales to zero between test sessions |
| prod | 1–3 / 1–3 | same | always warm; the delete-lock and Key Vault purge protection are on |

Edit `deploy/params/<env>.bicepparam` to change any of these.

## First deploy of an environment

```bash
az login
bash deploy/deploy.sh dev        # or qa | uat | prod
```

It creates the shared registry (once), the environment's resource group and foundation, offers to load the Groww
secrets from `backend/key.txt` into that environment's Key Vault, builds and pushes the images, and creates the apps.
After that, deploys are done by the GitHub pipeline (see GITHUB_SETUP.md). Re-run `deploy.sh` any time you need to
repair an environment.

## Test locally first

```bash
docker compose up --build      # http://localhost:3000
```

Only port 3000 is published; the backend is reachable from the frontend container only. This mirrors Azure.

## Things to do before relying on it

1. **Put authentication on the frontend.** The app shows your Groww margin and holdings. With a public URL, *anyone who
   finds it can see them.* Turn on Container Apps authentication (Microsoft Entra ID) on `ca-frontend`
   (portal: *ca-frontend → Authentication → Add identity provider*). See GITHUB_SETUP.md section 9 for the smoke test.
2. **Check Groww and Yahoo from Azure.** I tested the containers locally, not from Azure. Groww may restrict API calls
   by source IP, and Yahoo may rate-limit cloud IPs. Container Apps outbound IPs are shared unless you add a VNet + NAT
   gateway with a static IP. Check `https://<frontend>/api/groww/status` after deploying.
3. **Cost: about US$15 per month for all four environments** (Central India retail rates, light traffic): prod about
   $10 (one frontend and one backend replica always on), the shared registry about $5, and dev/qa/uat about $0 because
   they scale to zero inside the free Container Apps allowance. Key Vault, Log Analytics (0.1 GB/day cap keeps it inside
   the free 5 GB/month), managed identities, the load-balanced ingress and the first 100 GB of egress cost nothing here.
   Replica caps keep unexpected traffic from running up a bill. The trade-off for scale-to-zero environments is a cold
   start on the first request after a quiet period. To get to about $0, host images in a free registry such as GitHub
   Container Registry instead (images hold no secrets, but a free registry needs public images or a pull token).

   No premium compute or networking is used (Consumption plan, ACR Basic, Key Vault Standard, no VNet, NAT gateway,
   private endpoint, Front Door or Application Gateway). Don't enable private endpoints or planned maintenance on an
   environment without checking pricing: they add a separate management charge.

## Good to know

- **Rotating secrets:** update the value in that environment's Key Vault, then restart the backend revision
  (`az containerapp revision restart ...`) or re-run the pipeline; Container Apps reads Key Vault secrets when a revision starts.
- **Idle environments are auto-deleted after 90 days.** Azure removes a Container Apps environment that has had "no
  active container apps or jobs running" for over 90 days. The docs don't say whether an app scaled to zero counts as
  active. If dev, qa or uat disappear after months of no use, run `bash deploy/deploy.sh <env>` to recreate them. prod
  keeps replicas running, so it's not affected.
- **Caches are per replica.** The first analysis request on each backend replica takes about 20 seconds.
- **Stricter lock-down (optional):** internal ingress already keeps the backend off the internet. To also stop other apps
  you might add to the environment from calling it, add a shared-header check, or use a VNet with NSG rules.
- **WAF / custom domain (optional):** put Azure Front Door in front of `ca-frontend`.
- **Registry fallback:** if ACR Tasks is blocked on your subscription type, build locally and push:
  `az acr login -n <acr>` → `docker build` → `docker tag` → `docker push`.
- **Key Vault network:** it allows public network access with RBAC. For stricter setups use a private endpoint.

## Tear down

Everything for an environment lives in its own resource group, so deleting it removes the apps, environment, Key Vault,
identity and log workspace.

```bash
az resource list -g rg-stockmarket-dev -o table          # look first: this is what will be deleted
az group delete -n rg-stockmarket-dev --yes --no-wait    # starts the deletion (takes a few minutes)
az group exists -n rg-stockmarket-dev                    # prints false once it's gone
```

- **prod is locked** (`CanNotDelete`). Remove the lock first: `az lock delete --name lock-prod-no-delete -g rg-stockmarket-prod`.
  Its Key Vault has purge protection, so it stays recoverable for 30 days and can't be purged early. To redeploy within
  that window use `az keyvault recover --name <vault>`.
- **dev/qa/uat Key Vaults are soft-deleted for 7 days**, along with their secrets. Purge to remove them immediately:
  `az keyvault purge --name <vault> --location centralindia` (`deploy.sh` also offers this when you redeploy).
- **The Log Analytics workspace is soft-deleted for 14 days.** Nothing to do if you redeploy with the same names; Azure
  recovers it. To erase it for good: `az monitor log-analytics workspace delete -g <rg> -n <workspace> --force --yes`.
- **Delete `rg-stockmarket-shared` last**, since running apps pull their images from the registry in it.

To keep an environment but cut its bill, shrink the live apps without redeploying:

```bash
az containerapp update -g rg-stockmarket-dev -n ca-frontend --min-replicas 0 --max-replicas 1 --cpu 0.25 --memory 0.5Gi
az containerapp update -g rg-stockmarket-dev -n ca-backend  --min-replicas 0 --max-replicas 1 --cpu 0.25 --memory 0.5Gi
```
