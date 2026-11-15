using '../main.bicep'

// PROD: always warm (no cold starts, and the environment is never idle), able to scale out to 3 replicas.
// For real redundancy set both min replicas to 2 (about $10/month more). For heavier use raise containerCpu / containerMemory.
// Values that change per run come from environment variables (set by deploy.sh or the GitHub pipeline):
//   IMAGE_TAG   image tag to deploy               (default: latest)
//   DEPLOY_APPS create the container apps         (default: true)
//   MANAGE_RBAC create role assignments / locks   (default: true; the pipeline sets false)
//   SHARED_RG   resource group of the shared registry (default: rg-stockmarket-shared)

param environmentName = 'prod'
param imageTag = readEnvironmentVariable('IMAGE_TAG', 'latest')
param deployApps = bool(readEnvironmentVariable('DEPLOY_APPS', 'true'))
param manageAccessControl = bool(readEnvironmentVariable('MANAGE_RBAC', 'true'))
param acrResourceGroup = readEnvironmentVariable('SHARED_RG', 'rg-stockmarket-shared')

// Scaling and size
param frontendMinReplicas = 1
param frontendMaxReplicas = 3
param backendMinReplicas = 1
param backendMaxReplicas = 3
param containerCpu = '0.25'
param containerMemory = '0.5Gi'
