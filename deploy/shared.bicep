// Shared resources used by every environment. Deploy ONCE into rg-stockmarket-shared:
//   az deployment group create -g rg-stockmarket-shared -f deploy/shared.bicep
//
// One registry for all environments: images are built once, tagged with the git commit, and the same image is
// promoted dev -> qa -> uat -> prod. (One Basic registry costs about $5/month; a registry per environment would
// multiply that.)

@description('Azure region')
param location string = resourceGroup().location

@description('Short prefix for resource names. Letters and digits only. Must match the value used by main.bicep.')
@minLength(3)
@maxLength(8)
param namePrefix string = 'stockmkt'

// Deterministic, so main.bicep can compute the same name without being told.
var acrName = toLower('acr${namePrefix}${take(uniqueString(subscription().subscriptionId, resourceGroup().name), 8)}')

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: { project: 'stockmarket', environment: 'shared' }
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false // pull with managed identities, push with Entra identities; no shared password
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
