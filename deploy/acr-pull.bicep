// Lets an environment's managed identity pull images from the shared registry.
// This is a module because the registry lives in a different resource group (rg-stockmarket-shared)
// from the environment that needs the permission.

@description('Name of the shared registry')
param acrName string

@description('Principal ID of the environment\'s user-assigned managed identity')
param principalId string

var acrPullRole = '7f951dda-4ed3-4680-a7ca-43fe172d538d' // built-in "AcrPull"

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, acrPullRole)
  scope: acr
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRole)
  }
}
