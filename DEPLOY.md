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
3. **Cost: about US$40 per month as configured** (Central India retail rates, light traffic). Almost all of it is the
   three always-on replicas (2 frontend + 1 backend, 0.5 vCPU / 1 GiB each, billed at the idle rate even with no
   traffic, about $35) plus Container Registry Basic (about $5). Key Vault, Log Analytics (first 5 GB/month free),
   the managed identity, the load-balanced ingress and the first 100 GB of egress are effectively free here.
   To cut it, edit `deploy/main.bicep`:
   - `frontendMinReplicas = 1` → about $27/month
   - `frontendMinReplicas = 0` and `backendMinReplicas = 0` (scale to zero) → about $5–8/month, at the price of a
     cold start on the first request after idle
   - 0.25 vCPU / 0.5 GiB per app instead of 0.5 / 1 → roughly half the compute cost

   No premium compute or networking is used (Consumption plan, ACR Basic, Key Vault Standard, no VNet, NAT
   gateway, private endpoint, Front Door or Application Gateway). Don't enable private endpoints or planned
   maintenance on the environment without checking pricing: they add a separate management charge.

## Good to know

- **Rotating secrets:** update the value in Key Vault, then restart the backend revision
  (`az containerapp revision restart ...`); Container Apps reads Key Vault secrets when a revision starts.
- **Caches are per replica.** The first analysis request on each backend replica takes ~20 seconds.
- **Stricter lock-down (optional):** internal ingress already keeps the backend off the internet. To also stop other apps
  you might add to the environment from calling it, add a shared-header check, or use a VNet with NSG rules.
- **WAF / custom domain (optional):** put Azure Front Door in front of `ca-frontend`.
- **Registry fallback:** if ACR Tasks is blocked on your subscription type, build locally and push:
  `az acr login -n <acr>` → `docker build` → `docker tag` → `docker push`.
- **Key Vault network:** it allows public network access with RBAC. For stricter setups use a private endpoint.
