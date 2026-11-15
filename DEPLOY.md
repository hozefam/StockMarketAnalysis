# Deploying to Azure Container Apps

## Architecture

```
 Internet ──HTTPS──▶  ca-frontend  (external ingress · 2–5 replicas · built-in load balancer)
                          │  server-side proxy: /api/*  →  BACKEND_URL
                          ▼
                      ca-backend   (INTERNAL ingress only · 1–3 replicas)  ──▶  Groww API
                          ▲
   Key Vault ── managed identity ─┘   (GROWW_TOTP_TOKEN / GROWW_TOTP_SECRET injected as env vars)

 Azure Container Registry  ◀── images built with `az acr build`, pulled by managed identity (no admin password)
```

| You asked for | How it is done |
|---|---|
| Containers | `backend/Dockerfile` (FastAPI, non-root) and `frontend/Dockerfile` (Next.js standalone, non-root). `.dockerignore` keeps `key.txt` out of the images. |
| Push to Azure Container Registry | `az acr build` builds in Azure and pushes straight to the registry; no local Docker needed. |
| Run on Azure Container Apps | `deploy/main.bicep` creates the environment, both apps, logs, identity and role assignments. |
| Frontend as the gateway | The browser only calls the frontend. `frontend/app/api/[...path]/route.js` forwards `/api/*` to the backend server-side, reading `BACKEND_URL` at runtime. |
| Backend callable only from the frontend | Backend ingress is `external: false`: no public endpoint at all, reachable only from apps inside the same environment. |
| Load balancer | Container Apps ingress load-balances across replicas. Frontend scales 2–5 on concurrent requests; backend 1–3. |
| Secrets in Key Vault | Secrets are stored in Key Vault (RBAC mode). The backend app references them by Key Vault URL through a user-assigned managed identity with the *Key Vault Secrets User* role. No secret appears in the image, the Bicep or the app config. |

## One-time deploy

Prerequisites: Azure CLI (`az login`), a subscription where you can create resources and role assignments, and your
real secrets in `backend/key.txt` (used once, to load them into Key Vault).

```bash
bash deploy/deploy.sh          # Git Bash / WSL / macOS / Linux
```

It: creates the resource group and foundation → stores the two secrets in Key Vault → builds and pushes both images →
creates the container apps → prints the public frontend URL. Override defaults with `RG=`, `LOCATION=`, `TAG=`.

To redeploy after a code change, re-run it (a new image tag is generated each time).

## Test locally first

```bash
docker compose up --build      # http://localhost:3000
```

Only port 3000 is published; the backend is reachable from the frontend container only. This mirrors Azure.

## Things you should do before relying on it

1. **Put authentication on the frontend.** The app shows your Groww margin and holdings. With a public URL, *anyone who
   finds it can see them.* Turn on Container Apps built-in auth (Microsoft Entra ID):
   `az containerapp auth microsoft update -g <rg> -n ca-frontend --client-id <app-reg-id> --client-secret-name ... --tenant-id ...`
   (or in the portal: *ca-frontend → Authentication → Add identity provider*). Alternatively remove the account pages.
2. **Check Groww and Yahoo from Azure.** I tested the containers locally, not from Azure. Groww may restrict API calls by
   source IP, and Yahoo may rate-limit cloud IPs. Container Apps outbound IPs are shared unless you add a VNet + NAT
   gateway with a static IP. Check `https://<frontend>/api/groww/status` after deploying.
3. **Cost: about US$5 per month with the default settings** (Central India retail rates). Both apps scale to zero
   when idle and run at the smallest size (0.25 vCPU / 0.5 GiB), so compute stays inside the monthly Container Apps free
   grant (180,000 vCPU-seconds, 360,000 GiB-seconds and 2 million requests), which is plenty for personal use. The one
   fixed cost is Container Registry Basic at about $5 a month; Azure has no free registry tier. Key Vault (cents),
   Log Analytics (a 0.1 GB/day cap keeps it inside the free 5 GB/month), the managed identity, the load-balanced
   ingress and the first 100 GB of egress cost nothing here. Replicas are capped at 2 per app so unexpected traffic
   cannot run up a bill. The trade-off is a cold start on the first request after a quiet period (a few seconds for the
   page, then a few more for the backend). To get to about $0, keep the images in a free registry such as GitHub
   Container Registry instead of ACR (the images hold no secrets, but a free registry needs public images or a pull
   token). To keep things warm instead, set `frontendMinReplicas = 1` in `deploy/main.bicep` (about $4 more per month).

   No premium compute or networking is used (Consumption plan, ACR Basic, Key Vault Standard, no VNet, NAT
   gateway, private endpoint, Front Door or Application Gateway). Don't enable private endpoints or planned
   maintenance on the environment without checking pricing: they add a separate management charge.

## Good to know

- **Rotating secrets:** update the value in Key Vault, then restart the backend revision
  (`az containerapp revision restart ...`); Container Apps reads Key Vault secrets when a revision starts.
- **Idle environments are auto-deleted after 90 days.** Azure removes a Container Apps environment that has had "no
  active container apps or jobs running" for over 90 days. The docs don't say whether an app scaled to zero counts as
  active. If you leave this untouched for months and the site disappears, just run `deploy.sh` again (it recreates
  everything). To rule the risk out, set `frontendMinReplicas = 1` in `deploy/main.bicep` (about $4 more per month),
  which keeps one replica running.
- **Caches are per replica.** The first analysis request on each backend replica takes ~20 seconds.
- **Stricter lock-down (optional):** internal ingress already keeps the backend off the internet. To also stop other apps
  you might add to the environment from calling it, add a shared-header check, or use a VNet with NSG rules.
- **WAF / custom domain (optional):** put Azure Front Door in front of `ca-frontend`.
- **Registry fallback:** if ACR Tasks is blocked on your subscription type, build locally and push:
  `az acr login -n <acr>` → `docker build` → `docker tag` → `docker push`.
- **Key Vault network:** it allows public network access with RBAC. For stricter setups use a private endpoint.

## Tear down (stop all charges)

Everything lives in one resource group, so deleting it removes the apps, environment, registry (and its images),
Key Vault, identity and log workspace.

```bash
az resource list -g rg-stockmarket -o table          # look first: this is what will be deleted
az group delete -n rg-stockmarket --yes --no-wait    # starts the deletion (takes a few minutes)
az group exists -n rg-stockmarket                    # prints false once it's gone
```

Or in the portal: *Resource groups → rg-stockmarket → Delete resource group*, then type the name to confirm.

Two things Azure keeps for a while after a group is deleted:

1. **Key Vault is soft-deleted for 7 days**, along with your Groww secrets. Purge it to remove them immediately (and to be
   able to redeploy with the same name, which is derived from the resource group):
   `az keyvault purge --name <key-vault-name> --location centralindia`
   (list soft-deleted vaults with `az keyvault list-deleted`).
2. **The Log Analytics workspace is soft-deleted for 14 days.** Nothing to do if you redeploy with the same names
   (`deploy.sh` does): Azure simply recovers it, with its old data. To erase it for good instead:
   `az monitor log-analytics workspace delete -g rg-stockmarket -n <workspace-name> --force --yes`

To keep the app but cut the bill instead, shrink the live apps without redeploying:

```bash
az containerapp update -g rg-stockmarket -n ca-frontend --min-replicas 0 --max-replicas 2 --cpu 0.25 --memory 0.5Gi
az containerapp update -g rg-stockmarket -n ca-backend  --min-replicas 0 --max-replicas 2 --cpu 0.25 --memory 0.5Gi
```
