// The deploy identity of one department environment. It lives in
// rg-<dept>-platform-identities, where it has no rights, so it cannot edit
// its own trust.

targetScope = 'resourceGroup'

param team string
param env string
param platformSharedRepo string
param location string
param tags object

resource deploy 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${team}-platform-${env}'
  location: location
  tags: tags
}

// Only platform-shared runs in environment <dept>-<env>, which deploys from
// main only and, for prod, needs the department's approval.
resource deployTrust 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: deploy
  name: 'github-${team}-${env}'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${platformSharedRepo}:environment:${team}-${env}'
    audiences: ['api://AzureADTokenExchange']
  }
}

output clientId string = deploy.properties.clientId
output principalId string = deploy.properties.principalId
