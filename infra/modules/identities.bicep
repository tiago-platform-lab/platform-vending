// The three identities of one project environment. They live in
// rg-<app>-identities, which only the vending identity can change, so no
// identity can edit its own federated credentials or roles.
//
//   deploy   GitHub `environment: <env>` logs in as this. Its rights on the
//            app's resource group are granted by env-access.bicep.
//   plan     GitHub pull requests log in as this. Read-only. Used for what-if.
//   runtime  The app runs as this. Gets AcrPull from registry-access.bicep and
//            its data roles from env-access.bicep.

targetScope = 'resourceGroup'

param appName string
param env string
param subjectPrefix string
param location string
param tags object

@description('GUID of the tier-0 "What-If Reader" role.')
param whatIfReaderRoleId string

var githubIssuer = 'https://token.actions.githubusercontent.com'
var audiences = ['api://AzureADTokenExchange']
var managedIdentityOperator = 'f1a07417-d97a-45cb-824c-7a7467783830'

resource deploy 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}-${env}-deploy'
  location: location
  tags: tags
}

resource deployTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deploy
  name: 'github-${env}'
  properties: {
    issuer: githubIssuer
    subject: '${subjectPrefix}:environment:${env}'
    audiences: audiences
  }
}

resource plan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}-${env}-plan'
  location: location
  tags: tags
}

resource planTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: plan
  name: 'github-pull-request'
  properties: {
    issuer: githubIssuer
    subject: '${subjectPrefix}:pull_request'
    audiences: audiences
  }
}

resource runtime 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${appName}-${env}-runtime'
  location: location
  tags: tags
}

// Lets the deploy identity attach the runtime identity to the Container App.
resource deployAssignsRuntime 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(runtime.id, deploy.id, managedIdentityOperator)
  scope: runtime
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', managedIdentityOperator)
    principalId: deploy.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Lets what-if resolve the `existing` runtime identity.
resource planReadsRuntime 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(runtime.id, plan.id, whatIfReaderRoleId)
  scope: runtime
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', whatIfReaderRoleId)
    principalId: plan.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output deployClientId string = deploy.properties.clientId
output deployPrincipalId string = deploy.properties.principalId
output planClientId string = plan.properties.clientId
output planPrincipalId string = plan.properties.principalId
output runtimePrincipalId string = runtime.properties.principalId
