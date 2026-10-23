// A project's access to the shared container registry.

targetScope = 'resourceGroup'

param registryName string
param runtimePrincipalId string
param deployPrincipalId string
param grantPush bool

var roles = {
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

// The app pulls its image as its runtime identity: no registry password.
resource runtimePull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, runtimePrincipalId, roles.acrPull)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPull)
    principalId: runtimePrincipalId
    principalType: 'ServicePrincipal'
  }
}

// The deploy workflow builds on the runner and pushes with `docker push`, which
// AcrPush covers. (`az acr build` would also need ACR Tasks rights.)
resource deployPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantPush) {
  name: guid(acr.id, deployPrincipalId, roles.acrPush)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.acrPush)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}
