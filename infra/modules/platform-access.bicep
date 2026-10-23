// A project's access to the shared platform resource group of one environment.

targetScope = 'resourceGroup'

param containerAppsEnvironmentName string
param deployPrincipalId string
param planPrincipalId string

var readerRole = 'acdd72a7-3b82-4ee1-a7d0-1a0f3d5f2d6e'

// The custom "Container Apps Environment Joiner" role of this platform resource
// group. platform-shared names it guid(resourceGroup().id, 'cae-joiner'), and this
// module runs in that same resource group, so the GUID is recomputed here instead
// of being copied by hand into platform.yaml. Keep both expressions in sync.
var caeJoinerRoleName = guid(resourceGroup().id, 'cae-joiner')

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

resource deployJoin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cae.id, deployPrincipalId, caeJoinerRoleName)
  scope: cae
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', caeJoinerRoleName)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// what-if resolves the `existing` environment, so the plan identity reads it.
resource planRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cae.id, planPrincipalId, readerRole)
  scope: cae
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRole)
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
  }
}
