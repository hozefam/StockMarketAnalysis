// StockMarket on Azure Container Apps
//
//   Internet ──▶ [ frontend  (external ingress, load-balanced, 2–5 replicas) ]
//                      │  server-side /api/* proxy over the private network
//                      ▼
//                [ backend   (INTERNAL ingress only, 1–3 replicas) ] ──▶ Groww API
//
//   Secrets live in Key Vault; the backend reads them through a managed identity (no secrets in images/config).
//
// Deploy in two passes (see deploy/deploy.sh): first deployApps=false (registry, vault, identity, environment),
// then push images + secrets, then deployApps=true.

@description('Azure region')
param location string = resourceGroup().location

@description('Short prefix for resource names')
@minLength(3)
@maxLength(12)
param namePrefix string = 'stockmkt'

@description('Create the container apps (needs images in the registry and secrets in Key Vault)')
param deployApps bool = false

@description('Image tag to deploy')
param imageTag string = 'latest'

@description('Frontend replica range. Min 0 = scale to zero when idle (free). Max is capped low so unexpected traffic cannot run up a bill.')
param frontendMinReplicas int = 0
param frontendMaxReplicas int = 2

@description('Backend replica range (0 = scale to zero when idle; the first request after idle has a short cold start)')
param backendMinReplicas int = 0
param backendMaxReplicas int = 2

@description('CPU and memory per replica (the analysis peaks around 75 MiB, so 0.25 vCPU / 0.5 GiB is plenty)')
param containerCpu string = '0.25'
param containerMemory string = '0.5Gi'

var token = uniqueString(resourceGroup().id)
var acrName = toLower('acr${namePrefix}${take(token, 8)}')
var kvName = toLower('kv-${namePrefix}-${take(token, 6)}')

// Built-in role definition IDs
var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var kvSecretsUserRole = '4633458b-17de-408a-b874-0445c86b69e6'

// ---------------- foundation ----------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}-${take(token, 6)}'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') } // ~3 GB/month max, inside the free 5 GB allowance
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}'
  location: location
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false // pull with managed identity, not a shared password
  }
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// identity may pull images and read secrets, nothing more
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, identity.id, acrPullRole)
  scope: acr
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
  }
}

resource kvRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, identity.id, kvSecretsUserRole)
  scope: kv
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRole)
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------- apps ----------------
var registryConfig = [
  {
    server: acr.properties.loginServer
    identity: identity.id
  }
]

// BACKEND: internal ingress => reachable only from other apps inside this environment (i.e. the frontend)
resource backend 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: 'ca-backend'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  dependsOn: [ acrPull, kvRead ]
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registryConfig
      secrets: [
        {
          name: 'groww-totp-token'
          keyVaultUrl: '${kv.properties.vaultUri}secrets/groww-totp-token'
          identity: identity.id
        }
        {
          name: 'groww-totp-secret'
          keyVaultUrl: '${kv.properties.vaultUri}secrets/groww-totp-secret'
          identity: identity.id
        }
      ]
      ingress: {
        external: false // <-- the important line: no public endpoint
        targetPort: 8000
        transport: 'auto'
        allowInsecure: true // plain HTTP is fine: traffic never leaves the private environment
      }
    }
    template: {
      containers: [
        {
          name: 'backend'
          image: '${acr.properties.loginServer}/stockmarket-backend:${imageTag}'
          resources: { cpu: json(containerCpu), memory: containerMemory }
          env: [
            { name: 'GROWW_TOTP_TOKEN', secretRef: 'groww-totp-token' }
            { name: 'GROWW_TOTP_SECRET', secretRef: 'groww-totp-secret' }
          ]
          probes: [
            { type: 'Liveness', httpGet: { path: '/', port: 8000 }, periodSeconds: 20 }
            { type: 'Readiness', httpGet: { path: '/', port: 8000 }, periodSeconds: 10 }
          ]
        }
      ]
      scale: {
        minReplicas: backendMinReplicas
        maxReplicas: backendMaxReplicas
        rules: [
          { name: 'http', http: { metadata: { concurrentRequests: '30' } } }
        ]
      }
    }
  }
}

// FRONTEND: the only public entry point. HTTPS by default; the platform load-balances across replicas.
resource frontend 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: 'ca-frontend'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  dependsOn: [ acrPull ]
  properties: {
    managedEnvironmentId: env.id
    configuration: {
      activeRevisionsMode: 'Single'
      registries: registryConfig
      ingress: {
        external: true
        targetPort: 3000
        transport: 'auto'
        allowInsecure: false // HTTP is redirected to HTTPS
      }
    }
    template: {
      containers: [
        {
          name: 'frontend'
          image: '${acr.properties.loginServer}/stockmarket-frontend:${imageTag}'
          resources: { cpu: json(containerCpu), memory: containerMemory }
          env: [
            // the gateway route in the frontend forwards /api/* here
            { name: 'BACKEND_URL', value: 'http://${backend!.properties.configuration.ingress.fqdn}' }
          ]
          probes: [
            { type: 'Liveness', httpGet: { path: '/', port: 3000 }, periodSeconds: 20 }
            { type: 'Readiness', httpGet: { path: '/', port: 3000 }, periodSeconds: 10 }
          ]
        }
      ]
      scale: {
        minReplicas: frontendMinReplicas
        maxReplicas: frontendMaxReplicas
        rules: [
          { name: 'http', http: { metadata: { concurrentRequests: '50' } } }
        ]
      }
    }
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output keyVaultName string = kv.name
output frontendUrl string = deployApps ? 'https://${frontend!.properties.configuration.ingress.fqdn}' : ''
