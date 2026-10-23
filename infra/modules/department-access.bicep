// Who may do what inside rg-<dept>-platform-<env>.
//
//   deploy   Contributor: platform-shared creates Log Analytics, the Container
//            Apps environment and the registry. It cannot grant roles.
//   plan     What-If Reader for the shared platform-shared PR identity.

targetScope = 'resourceGroup'

param deployPrincipalId string
param planPrincipalId string
param whatIfReaderRoleId string

var contributorRole = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

resource deployContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployPrincipalId, contributorRole)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', contributorRole)
    principalId: deployPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource planWhatIf 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, planPrincipalId, whatIfReaderRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', whatIfReaderRoleId)
    principalId: planPrincipalId
    principalType: 'ServicePrincipal'
  }
}
