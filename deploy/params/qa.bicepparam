using '../main.bicep'

// QA: scale to zero, smallest size, up to two replicas so scale-out can be tested.
// Values that change per run come from environment variables (set by deploy.sh or the GitHub pipeline):
//   IMAGE_TAG   image tag to deploy               (default: latest)
//   DEPLOY_APPS create the container apps         (default: true)
//   MANAGE_RBAC create role assignments / locks   (default: true; the pipeline sets false)
//   SHARED_RG   resource group of the shared registry (default: rg-stockmarket-shared)

param environmentName = 'qa'
param imageTag = readEnvironmentVariable('IMAGE_TAG', 'latest')
param deployApps = bool(readEnvironmentVariable('DEPLOY_APPS', 'true'))
param manageAccessControl = bool(readEnvironmentVariable('MANAGE_RBAC', 'true'))
param acrResourceGroup = readEnvironmentVariable('SHARED_RG', 'rg-stockmarket-shared')

// Scaling and size
param frontendMinReplicas = 0
param frontendMaxReplicas = 2
param backendMinReplicas = 0
param backendMaxReplicas = 2
param containerCpu = '0.25'
param containerMemory = '0.5Gi'
