// What a project's identities may do inside rg-<app>-<env>.
//
//   deploy   Contributor: creates and updates the app's resources. It cannot
//            grant roles, so a compromised pipeline cannot widen anyone's access.
//   plan     What-If Reader (tier-0 custom role): read and what-if, but no
//            log queries or image pulls, since it runs unreviewed PR code.
//   runtime  The data roles the app needs, granted here at resource-group scope
//            so they cover whatever Key Vault or storage account the app's own
//            Bicep creates later. The group holds only this app's resources.
//
// An app that needs a role not listed here asks for it through its
// projects/<app>.yaml record, so every grant is reviewed in one place.

targetScope = 'resourceGroup'

param deployPrincipalId string
param planPrincipalId string
param runtimePrincipalId string

@description('GUID of the tier-0 "What-If Reader" role.')
param whatIfReaderRoleId string

var contributorRole = 'b24988ac-6180-42a0-ab88-20f7382dd24c'

var runtimeRoles = [
  '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor
]

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

resource runtimeData 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in runtimeRoles: {
  name: guid(resourceGroup().id, runtimePrincipalId, role)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
    principalId: runtimePrincipalId
    principalType: 'ServicePrincipal'
  }
}]
