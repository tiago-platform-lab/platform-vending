// A project's access to the shared platform resource group of one environment.

targetScope = 'resourceGroup'

param containerAppsEnvironmentName string
param deployPrincipalId string
param planPrincipalId string

@description('GUID of the tier-0 "Container Apps Environment Joiner" role.')
param caeJoinerRoleId string

@description('GUID of the tier-0 "What-If Reader" role.')
param whatIfReaderRoleId string

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: containerAppsEnvironmentName
}

// One Joiner definition serves every department: it is assigned on this one
// environment only, so the app cannot join another department's environment.
resource deployJoin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cae.id, deployPrincipalId, caeJoinerRoleId)
  scope: cae
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', caeJoinerRoleId)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// what-if resolves the `existing` environment, so the plan identity reads it.
resource planRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cae.id, planPrincipalId, whatIfReaderRoleId)
  scope: cae
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', whatIfReaderRoleId)
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
  }
}
