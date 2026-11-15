// StockMarket on Azure Container Apps: ONE ENVIRONMENT (dev | qa | uat | prod)
//
// Deploy one resource group per environment, e.g. rg-stockmarket-dev, with the matching parameter file:
//   az deployment group create -g rg-stockmarket-dev -f deploy/main.bicep -p deploy/params/dev.bicepparam
//
//   Internet ──▶ [ frontend  (external ingress, load-balanced) ]
//                      │  server-side /api/* proxy over the private network
//                      ▼
//                [ backend   (INTERNAL ingress only) ] ──▶ Groww API
//
//   Secrets live in this environment's Key Vault; the backend reads them through a managed identity.
//   The container registry is shared by all environments (deploy/shared.bicep).
//
// Two kinds of deployer (see GITHUB_SETUP.md):
//   * a person/bootstrap script with Owner rights: manageAccessControl = true  (role assignments, prod lock)
//   * the GitHub pipeline with Contributor only:   manageAccessControl = false (just updates the apps)

@description('Azure region')
param location string = resourceGroup().location

@description('Which environment this deployment is')
@allowed([ 'dev', 'qa', 'uat', 'prod' ])
param environmentName string

@description('Short prefix for resource names. Letters and digits only. Must match shared.bicep.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'stockmkt'

@description('Resource group holding the shared registry')
param acrResourceGroup string = 'rg-stockmarket-shared'

@description('Create the container apps (needs images in the registry and secrets in Key Vault)')
param deployApps bool = false

@description('Create role assignments (and the prod delete-lock). Needs Owner / User Access Administrator; the pipeline sets this to false.')
param manageAccessControl bool = true

@description('Image tag to deploy (the pipeline uses the git commit SHA)')
param imageTag string = 'latest'

@description('Frontend replica range. Min 0 = scale to zero when idle (free). Keep max low so unexpected traffic cannot run up a bill.')
param frontendMinReplicas int = 0
param frontendMaxReplicas int = 2

@description('Backend replica range (0 = scale to zero when idle; the first request after idle has a short cold start)')
param backendMinReplicas int = 0
param backendMaxReplicas int = 2

@description('CPU and memory per replica (the analysis peaks around 75 MiB, so 0.25 vCPU / 0.5 GiB is plenty)')
param containerCpu string = '0.25'
param containerMemory string = '0.5Gi'

var isProd = environmentName == 'prod'
var token = uniqueString(resourceGroup().id)
var tags = {
  project: 'stockmarket'
  environment: environmentName
}

// Same formula as shared.bicep, so the registry name never has to be passed around.
var acrName = toLower('acr${namePrefix}${take(uniqueString(subscription().subscriptionId, acrResourceGroup), 8)}')
var kvName = toLower('kv-${namePrefix}-${environmentName}-${take(token, 6)}')

// Built-in role definition IDs
var kvSecretsUserRole = '4633458b-17de-408a-b874-0445c86b69e6'

// ---------------- shared registry (lives in another resource group) ----------------
// Only the registry's address is needed here, and it is computed from its name, so the deployer needs NO access to the
// shared resource group. (An earlier version read the registry resource and the pipeline identity was denied.)
var acrLoginServer = '${acrName}.azurecr.io'

// ---------------- per-environment foundation ----------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${namePrefix}-${environmentName}-${take(token, 6)}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') } // ~3 GB/month max, inside the free 5 GB allowance
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}-${environmentName}'
  location: location
  tags: tags
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: isProd ? 30 : 7
    enablePurgeProtection: isProd ? true : null // prod secrets cannot be purged early (cannot be turned off once on)
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------- access control (needs elevated rights; skipped by the pipeline) ----------------
// the environment's identity may pull images from the shared registry...
module acrPull 'acr-pull.bicep' = if (manageAccessControl) {
  name: 'acr-pull-${environmentName}'
  scope: resourceGroup(acrResourceGroup)
  params: {
    acrName: acrName
    principalId: identity.properties.principalId
  }
}

// ...and read this environment's secrets, nothing more
resource kvRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (manageAccessControl) {
  name: guid(kv.id, identity.id, kvSecretsUserRole)
  scope: kv
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRole)
  }
}

// prod cannot be deleted by accident (remove the lock first if you really mean it)
resource prodLock 'Microsoft.Authorization/locks@2020-05-01' = if (manageAccessControl && isProd) {
  name: 'lock-prod-no-delete'
  properties: {
    level: 'CanNotDelete'
    notes: 'Production resource group. Remove this lock before deleting.'
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${namePrefix}-${environmentName}'
  location: location
  tags: tags
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
    server: acrLoginServer
    identity: identity.id
  }
]

// BACKEND: internal ingress => reachable only from other apps inside this environment (i.e. the frontend)
resource backend 'Microsoft.App/containerApps@2024-03-01' = if (deployApps) {
  name: 'ca-backend'
  location: location
  tags: tags
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
          image: '${acrLoginServer}/stockmarket-backend:${imageTag}'
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
  tags: tags
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
          image: '${acrLoginServer}/stockmarket-frontend:${imageTag}'
          resources: { cpu: json(containerCpu), memory: containerMemory }
          env: [
            // the gateway route in the frontend forwards /api/* here
            { name: 'BACKEND_URL', value: 'http://${backend!.properties.configuration.ingress.fqdn}' }
            // shown as a badge in the UI for every environment except prod
            { name: 'APP_ENV', value: environmentName }
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

output environmentName string = environmentName
output acrName string = acrName
output acrLoginServer string = acrLoginServer
output keyVaultName string = kv.name
output frontendUrl string = deployApps ? 'https://${frontend!.properties.configuration.ingress.fqdn}' : ''
