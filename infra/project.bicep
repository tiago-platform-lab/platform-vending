// Vends one project into Azure:
//   rg-<app>-identities   the project's identities and their OIDC trust
//   rg-<app>-<env>        one per environment, where the app's own Bicep deploys
// plus the project's access to the shared platform layer and registry.
//
// Deployed at subscription scope by the vending identity. It writes in several
// places, so it needs rights in several places (see bootstrap/tier0.bicep).
// Every role it assigns must be in the list tier0.bicep allows it to assign.

targetScope = 'subscription'

@minLength(3)
@maxLength(16)
param appName string

@description('GitHub OIDC subject prefix of the repo, exactly as GitHub reports it (gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix), e.g. repo:org@123/name@456.')
param subjectPrefix string

param location string = 'swedencentral'
param tags object

@description('Environments to create, e.g. ["dev", "prod"].')
param environments array = ['dev', 'prod']

@description('Per environment: resourceGroup, containerAppsEnvironmentName. From platform.yaml.')
param platform object

@description('The one shared registry: resourceGroup, name. From platform.yaml.')
param registry object

@description('GUIDs of the tier-0 custom roles: caeJoiner, whatIfReader. From platform.yaml.')
param roles object

var baseTags = union(tags, { project: appName })

resource identityRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${appName}-identities'
  location: location
  tags: baseTags
}

resource envRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [for e in environments: {
  name: 'rg-${appName}-${e}'
  location: location
  tags: union(baseTags, { env: e })
}]

module ids 'modules/identities.bicep' = [for e in environments: {
  name: 'vend-ids-${appName}-${e}'
  scope: identityRg
  params: {
    appName: appName
    env: e
    subjectPrefix: subjectPrefix
    location: location
    tags: union(baseTags, { env: e })
    whatIfReaderRoleId: roles.whatIfReader
  }
}]

module envAccess 'modules/env-access.bicep' = [for (e, i) in environments: {
  name: 'vend-env-${appName}-${e}'
  scope: envRgs[i]
  params: {
    deployPrincipalId: ids[i].outputs.deployPrincipalId
    planPrincipalId: ids[i].outputs.planPrincipalId
    runtimePrincipalId: ids[i].outputs.runtimePrincipalId
    whatIfReaderRoleId: roles.whatIfReader
  }
}]

module platformAccess 'modules/platform-access.bicep' = [for (e, i) in environments: {
  name: 'vend-platform-${appName}-${e}'
  scope: resourceGroup(platform[e].resourceGroup)
  params: {
    containerAppsEnvironmentName: platform[e].containerAppsEnvironmentName
    deployPrincipalId: ids[i].outputs.deployPrincipalId
    planPrincipalId: ids[i].outputs.planPrincipalId
    caeJoinerRoleId: roles.caeJoiner
    whatIfReaderRoleId: roles.whatIfReader
  }
}]

module registryAccess 'modules/registry-access.bicep' = [for (e, i) in environments: {
  name: 'vend-acr-${appName}-${e}'
  scope: resourceGroup(registry.resourceGroup)
  params: {
    registryName: registry.name
    runtimePrincipalId: ids[i].outputs.runtimePrincipalId
    deployPrincipalId: ids[i].outputs.deployPrincipalId
    // Images are built once, in dev, and promoted; only dev may push.
    grantPush: e == 'dev'
  }
}]

output identityResourceGroup string = identityRg.name
output environments array = [for (e, i) in environments: {
  env: e
  resourceGroup: envRgs[i].name
  deployClientId: ids[i].outputs.deployClientId
  planClientId: ids[i].outputs.planClientId
}]
