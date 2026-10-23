#!/usr/bin/env bash
# Last GitHub step of vending one project: wire the repo (created earlier by
# create-repo.sh) to its Azure identities. Safe to re-run: every call either
# creates or overwrites with the same value.
#
# Usage: configure-repo.sh <projects/x.yaml> <platform.yaml> <azure-outputs.json>
# Needs: GH_TOKEN (vending GitHub App), AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
#
# The GitHub App needs, on the org: Administration (rw), Variables (rw),
# Environments (rw), Custom properties (rw), Members (r), Contents (r),
# Actions (r).
set -euo pipefail

project=$1
platform=$2
outputs=$3

name=$(yq '.name' "$project")
repo=$(yq '.repo' "$project")
team=$(yq '.team' "$project")
approvers=$(yq '.prodApprovers' "$project")
dept=$(yq '.department' "$project")
org=$(yq '.github.org' "$platform")

# The department's slice of platform.yaml.
pf() { yq ".departments.\"$dept\"$1" "$platform"; }
[ "$(pf '')" != "null" ] || { echo "unknown department '$dept'" >&2; exit 1; }

echo "Configuring $repo (department $dept)"

# 1. (The repo itself was created by create-repo.sh.)

# 2. Owning team
gh api -X PUT "orgs/$org/teams/$team/repos/$repo" -f permission=maintain > /dev/null

# 3. Repo-level variables. Not secrets: OIDC needs none.
repo_var() { gh variable set "$1" --repo "$repo" --body "$2"; }
repo_var AZURE_TENANT_ID "$AZURE_TENANT_ID"
repo_var AZURE_SUBSCRIPTION_ID "$AZURE_SUBSCRIPTION_ID"
repo_var APP_NAME "$name"
repo_var ACR_NAME "$(pf '.registry.name')"
repo_var ACR_LOGIN_SERVER "$(pf '.registry.loginServer')"
repo_var IDENTITY_RG "$(jq -r '.identityResourceGroup.value' "$outputs")"
repo_var TAG_DEPT "$(yq '.tags.dept' "$project")"
repo_var TAG_OWNER "$(yq '.tags.owner' "$project")"
repo_var TAG_COST_CENTRE "$(yq '.tags["cost-centre"]' "$project")"

# 4. One GitHub environment per Azure environment. The deploy identity trusts
#    exactly `repo:<repo>:environment:<env>`, so these names must match.
approvers_id=$(gh api "orgs/$org/teams/$approvers" --jq .id)

while IFS= read -r row; do
  env=$(jq -r '.env' <<< "$row")
  upper=${env^^}
  platform_rg=$(pf ".environments.$env.resourceGroup")
  cae=$(pf ".environments.$env.containerAppsEnvironmentName")

  if [ "$env" = "prod" ]; then
    reviewers=$(jq -n --argjson id "$approvers_id" '[{type: "Team", id: $id}]')
  else
    reviewers='[]'
  fi
  jq -n --argjson r "$reviewers" \
    '{reviewers: $r, deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
    gh api -X PUT "repos/$repo/environments/$env" --input - > /dev/null
  # Only main may deploy. Fails harmlessly if the policy already exists.
  gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" -f name=main > /dev/null 2>&1 || true

  env_var() { gh variable set "$1" --repo "$repo" --env "$env" --body "$2"; }
  env_var AZURE_CLIENT_ID "$(jq -r '.deployClientId' <<< "$row")"
  env_var RESOURCE_GROUP "$(jq -r '.resourceGroup' <<< "$row")"
  env_var PLATFORM_RG "$platform_rg"
  env_var CAE_NAME "$cae"

  # Pull requests run outside any environment, so the plan job reads these.
  repo_var "PLAN_CLIENT_ID_$upper" "$(jq -r '.planClientId' <<< "$row")"
  repo_var "RG_$upper" "$(jq -r '.resourceGroup' <<< "$row")"
  repo_var "PLATFORM_RG_$upper" "$platform_rg"
  repo_var "CAE_NAME_$upper" "$cae"
done < <(jq -c '.environments.value[]' "$outputs")

# 5. Custom properties, defined once at org level (see README "Bootstrap").
#    Optional: an org without them defined (e.g. a test org) only gets a warning.
jq -n \
  --arg owner "$(yq '.tags.owner' "$project")" \
  --arg cc "$(yq '.tags["cost-centre"]' "$project")" \
  '{properties: [
     {property_name: "owner", value: $owner},
     {property_name: "cost-centre", value: $cc},
     {property_name: "vended", value: "true"}]}' |
  gh api -X PATCH "repos/$repo/properties/values" --input - > /dev/null \
  || echo "::warning::custom properties not set on $repo (not defined on the org?)"

echo "  done"
