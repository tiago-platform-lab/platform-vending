// Tier 0: what everything else stands on. Deployed once, by hand, by someone
// who is Owner of the subscription (central IT at the company):
//
//   az deployment sub create -l swedencentral -f bootstrap/tier0.bicep -p bootstrap/tier0.bicepparam
//
// It creates:
//   - the two custom roles every department and app uses (fixed GUIDs, also in
//     platform.yaml): "Container Apps Environment Joiner" and "What-If Reader"
//   - rg-platform-identities with the two platform identities:
//       id-vending        runs platform-vending (environment `vending` only)
//       id-platform-plan  runs what-if on platform-shared pull requests
//   - id-vending's rights: Contributor on the subscription, and Role Based
//     Access Control Administrator limited to a closed list of roles, granted
//     to service principals only. Nothing it creates can grant roles in turn.
//   - optionally, an email alert on any change to federated credentials.
//
// Known, accepted risk: id-vending is Contributor on the subscription that
// holds rg-platform-identities, so a stolen vending token could edit
// id-vending's own federated credentials. Mitigated by pinning actions by SHA,
// the `vending` environment approval and the alert below. At the company, put
// rg-platform-identities in IT's management subscription instead (same file,
// deployed there, with the role assignments targeting the workload subscription).

targetScope = 'subscription'

param location string = 'swedencentral'
param tags object

@description('platform-vending: GitHub OIDC subject prefix of the repo, exactly as GitHub reports it (gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix), e.g. repo:org@123/name@456.')
param vendingSubjectPrefix string

@description('platform-shared: GitHub OIDC subject prefix of the repo, exactly as GitHub reports it (gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix), e.g. repo:org@123/name@456.')
param platformSharedSubjectPrefix string

@description('Email for the federated-credential alert. Empty: no alert.')
param alertEmail string = ''

// Fixed GUIDs, so platform.yaml can name them before they exist. Keep in sync.
var caeJoinerRoleId = 'ae166dd6-747a-401b-b70f-8533acfae304'
var whatIfReaderRoleId = '4b16aabd-f527-4007-9d57-9ce3a5eba870'

var builtIn = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  rbacAdministrator: 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
  managedIdentityOperator: 'f1a07417-d97a-45cb-824c-7a7467783830'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
  acrPush: '8311e382-0749-4cb8-b61a-304f252e45ec'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
}

// ---------------- custom roles ----------------

// Lets an app's deploy identity place a Container App in a shared environment
// without any right to change the environment. One definition for every
// department: isolation comes from where it is assigned (one environment).
resource caeJoinerRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: caeJoinerRoleId
  properties: {
    roleName: 'Container Apps Environment Joiner'
    description: 'Deploy Container Apps and Jobs into a shared Container Apps environment.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.App/managedEnvironments/read'
          'Microsoft.App/managedEnvironments/join/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: [subscription().id]
  }
}

// For identities that run on pull requests, i.e. on unreviewed code: enough to
// preview a deployment, nothing that reads data. Reader would also allow
// querying Log Analytics and pulling images.
// TODO(verify in test): what-if with --validation-level ProviderNoRbac works
// with exactly this set.
resource whatIfReaderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: whatIfReaderRoleId
  properties: {
    roleName: 'What-If Reader'
    description: 'Read resource configuration and run deployment what-if. No data access.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          '*/read'
          'Microsoft.Resources/deployments/validate/action'
          'Microsoft.Resources/deployments/whatIf/action'
        ]
        notActions: [
          'Microsoft.OperationalInsights/workspaces/query/*'
          'Microsoft.OperationalInsights/workspaces/tables/query/*'
          'Microsoft.Insights/logs/*'
          'Microsoft.ContainerRegistry/registries/pull/read'
        ]
      }
    ]
    assignableScopes: [subscription().id]
  }
}

// ---------------- platform identities ----------------

resource identityRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-platform-identities'
  location: location
  tags: tags
}

module identities 'modules/tier0-identities.bicep' = {
  name: 'tier0-identities'
  scope: identityRg
  params: {
    location: location
    tags: tags
    vendingSubjectPrefix: vendingSubjectPrefix
    platformSharedSubjectPrefix: platformSharedSubjectPrefix
    alertEmail: alertEmail
  }
}

// ---------------- what id-vending may do ----------------

resource vendingContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, 'id-vending', builtIn.contributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtIn.contributor)
    principalId: identities.outputs.vendingPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// The only roles vending may assign or remove. Owner, User Access
// Administrator and RBAC Administrator are not here, so nothing vending creates
// can grant roles. Every role in project.bicep and its modules must be listed.
var assignable = join([
  builtIn.contributor
  builtIn.managedIdentityOperator
  builtIn.acrPull
  builtIn.acrPush
  builtIn.keyVaultSecretsUser
  builtIn.storageBlobDataContributor
  builtIn.storageQueueDataContributor
  caeJoinerRoleId
  whatIfReaderRoleId
], ', ')

var vendingCondition = '((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/write\'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${assignable}} AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase \'ServicePrincipal\')) AND ((!(ActionMatches{\'Microsoft.Authorization/roleAssignments/delete\'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${assignable}}))'

resource vendingRbacAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, 'id-vending', builtIn.rbacAdministrator)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', builtIn.rbacAdministrator)
    principalId: identities.outputs.vendingPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Vending may assign only the roles in tier0.bicep, to service principals only.'
    condition: vendingCondition
    conditionVersion: '2.0'
  }
  // The condition names the custom roles, which must exist first.
  dependsOn: [caeJoinerRole, whatIfReaderRole]
}

output vendingClientId string = identities.outputs.vendingClientId
output platformPlanClientId string = identities.outputs.planClientId
output platformPlanPrincipalId string = identities.outputs.planPrincipalId
output roles object = {
  caeJoiner: caeJoinerRole.name
  whatIfReader: whatIfReaderRole.name
}
