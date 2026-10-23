// The platform identities, in rg-platform-identities. No pipeline identity has
// a role on this resource group (see the accepted risk in tier0.bicep).

targetScope = 'resourceGroup'

param location string
param tags object
param vendingRepo string
param platformSharedRepo string
param alertEmail string

var githubIssuer = 'https://token.actions.githubusercontent.com'
var audiences = ['api://AzureADTokenExchange']

resource vending 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-vending'
  location: location
  tags: tags
}

// Only the approved `vending` environment of platform-vending, never a PR.
resource vendingTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: vending
  name: 'github-vending'
  properties: {
    issuer: githubIssuer
    subject: 'repo:${vendingRepo}:environment:vending'
    audiences: audiences
  }
}

// One read-only identity for every platform-shared pull request. Splitting it
// per department would not isolate anything: all PRs of that repo present the
// same subject. Vending (or the department bootstrap) gives it What-If Reader
// on each department's platform resource groups.
resource plan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-platform-plan'
  location: location
  tags: tags
}

resource planTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: plan
  name: 'github-pull-request'
  properties: {
    issuer: githubIssuer
    subject: 'repo:${platformSharedRepo}:pull_request'
    audiences: audiences
  }
  // Federated credentials of one identity cannot be written in parallel.
  dependsOn: [vendingTrust]
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmail)) {
  name: 'ag-platform-security'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'platformsec'
    enabled: true
    emailReceivers: [
      { name: 'platform-owner', emailAddress: alertEmail, useCommonAlertSchema: true }
    ]
  }
}

// Someone changed who an identity trusts. Lives here but watches the whole
// subscription.
resource credentialAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (!empty(alertEmail)) {
  name: 'alert-federated-credential-change'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    description: 'A federated credential was created, changed or deleted. Expected when vending runs; anything else is suspicious.'
    scopes: [subscription().id]
    // Azure requires a plain filter besides the category on a subscription-wide
    // Administrative alert (an anyOf does not count). Filtering on the resource
    // type catches writes and deletes; reads are not in the activity log.
    condition: {
      allOf: [
        { field: 'category', equals: 'Administrative' }
        { field: 'resourceType', equals: 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials' }
      ]
    }
    actions: {
      actionGroups: [{ actionGroupId: actionGroup.id }]
    }
  }
}

output vendingClientId string = vending.properties.clientId
output vendingPrincipalId string = vending.properties.principalId
output planClientId string = plan.properties.clientId
output planPrincipalId string = plan.properties.principalId
