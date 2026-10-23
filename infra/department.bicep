// Prepares Azure for one new department, before platform-shared deploys its base:
//   rg-<dept>-platform-identities   the department's deploy identities
//   rg-<dept>-platform-<env>        where platform-shared deploys (empty here)
//   id-<dept>-platform-<env>        trusts platform-shared, environment <dept>-<env>;
//                                   Contributor on rg-<dept>-platform-<env> only
//   What-If Reader for id-platform-plan on each rg-<dept>-platform-<env>
//
// Phase 1: run by hand, once per department:
//   az deployment sub create -n dept-<dept> -l swedencentral -f infra/department.bicep \
//     -p team=<dept> planPrincipalId=<tier0 output> ...
// Phase 2: run by vend-project.yml from departments/<dept>.yaml. It only assigns
// roles from the vending identity's list (Contributor, What-If Reader), so it
// can move to vending unchanged.

targetScope = 'subscription'

@description('Department short name. Lowercase letters and digits: it is part of the registry name.')
@minLength(2)
@maxLength(10)
param team string

param environments array = ['dev', 'prod']
param location string = 'swedencentral'
param tags object

@description('owner/name of the platform-shared repo.')
param platformSharedRepo string

@description('Principal ID of id-platform-plan (tier0 output platformPlanPrincipalId).')
param planPrincipalId string

@description('GUID of the tier-0 "What-If Reader" role (platform.yaml azure.roles.whatIfReader).')
param whatIfReaderRoleId string

var baseTags = union(tags, { dept: team, project: 'platform' })

resource identityRg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${team}-platform-identities'
  location: location
  tags: baseTags
}

resource envRgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [for e in environments: {
  name: 'rg-${team}-platform-${e}'
  location: location
  tags: union(baseTags, { env: e })
}]

module ids 'modules/department-identity.bicep' = [for e in environments: {
  name: 'dept-id-${team}-${e}'
  scope: identityRg
  params: {
    team: team
    env: e
    platformSharedRepo: platformSharedRepo
    location: location
    tags: union(baseTags, { env: e })
  }
}]

module access 'modules/department-access.bicep' = [for (e, i) in environments: {
  name: 'dept-access-${team}-${e}'
  scope: envRgs[i]
  params: {
    deployPrincipalId: ids[i].outputs.principalId
    planPrincipalId: planPrincipalId
    whatIfReaderRoleId: whatIfReaderRoleId
  }
}]

// For the GitHub environments <dept>-<env> of platform-shared (AZURE_CLIENT_ID).
output environments array = [for (e, i) in environments: {
  env: e
  githubEnvironment: '${team}-${e}'
  resourceGroup: envRgs[i].name
  deployClientId: ids[i].outputs.clientId
}]
