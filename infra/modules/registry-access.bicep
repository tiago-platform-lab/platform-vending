// A project's access to its department's shared container registry, limited to
// the project's own repository (<registry>/<app>).
//
// The registry runs in "RBAC Registry + ABAC Repository Permissions" mode
// (platform-shared), where AcrPull/AcrPush are not honoured. The ABAC-enabled
// roles below carry a condition on the repository name, so an app can neither
// read nor overwrite another app's images, even in the same registry.

targetScope = 'resourceGroup'

param registryName string
@description('Repository the app pushes to and pulls from: the app name.')
param repositoryName string
param runtimePrincipalId string
param deployPrincipalId string
param grantPush bool

var roles = {
  repositoryReader: 'b93aa761-3e63-49ed-ac28-beffa264f7ac' // Container Registry Repository Reader
  repositoryWriter: '2a1e307c-b015-4ebd-883e-5b7698a07328' // Container Registry Repository Writer
}

// Every data action of the role is allowed only on this repository.
var onlyThisRepository = '@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${repositoryName}\''
var readCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (${onlyThisRepository}))'
var writeCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (${onlyThisRepository}))'

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: registryName
}

// The app pulls its own image as its runtime identity: no registry password.
resource runtimePull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, runtimePrincipalId, roles.repositoryReader)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.repositoryReader)
    principalId: runtimePrincipalId
    principalType: 'ServicePrincipal'
    description: 'Pull ${repositoryName} only'
    condition: readCondition
    conditionVersion: '2.0'
  }
}

// The dev deploy workflow builds on the runner and pushes with `docker push`;
// release.yml adds version tags to the same repository.
resource deployPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantPush) {
  name: guid(acr.id, deployPrincipalId, roles.repositoryWriter)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.repositoryWriter)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Push and tag ${repositoryName} only'
    condition: writeCondition
    conditionVersion: '2.0'
  }
}
