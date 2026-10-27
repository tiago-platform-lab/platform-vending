#!/usr/bin/env bash
# Last GitHub step of vending one project: wire the repo (created earlier by
# create-repo.sh) to its Azure identities. Safe to re-run: every call either
# creates or overwrites with the same value.
#
# Usage: configure-repo.sh <projects/x.yaml> <platform.yaml> <azure-outputs.json>
# Needs: GH_TOKEN (vending GitHub App), AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID
#
# The GitHub App needs, on the org: Administration (rw), Variables (rw),
# Environments (rw), Custom properties (rw), Members (r), Contents (rw: CODEOWNERS),
# Actions (rw: reads the OIDC subject prefix, starts the first deploy).
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

# Make the refs that may deploy to an environment exactly the given list, e.g.
# `branch:main tag:v*`. Refs no longer wanted are removed, so re-running an
# older project brings it up to date.
set_deploy_refs() {
  local env=$1; shift
  local want=" $* " id type name ref
  while IFS=$'\t' read -r id type name; do
    [[ "$want" == *" $type:$name "* ]] \
      || gh api -X DELETE "repos/$repo/environments/$env/deployment-branch-policies/$id" > /dev/null
  done < <(gh api "repos/$repo/environments/$env/deployment-branch-policies" \
             --jq '.branch_policies[] | [.id, (.type // "branch"), .name] | @tsv')
  for ref in "$@"; do
    # Fails harmlessly if the policy already exists.
    gh api -X POST "repos/$repo/environments/$env/deployment-branch-policies" \
      -f type="${ref%%:*}" -f name="${ref#*:}" > /dev/null 2>&1 || true
  done
}

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
  # dev: every merge to main, plus release tags (release.yml names the image
  # with the version as the dev identity, the only one that can write to the
  # registry). prod: release tags only, so prod only ever gets a version.
  if [ "$env" = "prod" ]; then
    set_deploy_refs "$env" 'tag:v*'
  else
    set_deploy_refs "$env" 'branch:main' 'tag:v*'
  fi

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

# 5. Release tags v*: only the owning team may create them, and nobody may move
#    or delete them, so a version always means the same commit and image.
team_id=$(gh api "orgs/$org/teams/$team" --jq .id)
ruleset() { # <name>, ruleset JSON on stdin; creates it or updates it in place
  local id
  id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$1\") | .id")
  if [ -n "$id" ]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - > /dev/null
  else
    gh api -X POST "repos/$repo/rulesets" --input - > /dev/null
  fi
}
tags='{ref_name: {include: ["refs/tags/v*"], exclude: []}}'
jq -n "{name: \"release-tags-immutable\", target: \"tag\", enforcement: \"active\",
        conditions: $tags, rules: [{type: \"update\"}, {type: \"deletion\"}]}" |
  ruleset release-tags-immutable
jq -n --argjson team "$team_id" "{name: \"release-tags-creators\", target: \"tag\", enforcement: \"active\",
        bypass_actors: [{actor_id: \$team, actor_type: \"Team\", bypass_mode: \"always\"}],
        conditions: $tags, rules: [{type: \"creation\"}]}" |
  ruleset release-tags-creators

# 6. Custom properties, defined once at org level (see README "Tier 0").
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

# 7. CODEOWNERS: the owning team reviews everything, the platform team also
#    reviews infra/. The template only has a placeholder. Written only when it
#    differs, so re-running vending adds no commits (and fixes older repos).
platform_team=$(yq '.github.platformTeam' "$platform")
desired=$(printf '%s\n' \
  "# Written by vending from projects/$name.yaml: the owning team reviews" \
  "# everything, the platform team also reviews infra/." \
  "* @$org/$team" \
  "/infra/ @$org/$team @$org/$platform_team")
current=""
current_sha=""
if meta=$(gh api "repos/$repo/contents/.github/CODEOWNERS" 2>/dev/null); then
  current_sha=$(jq -r .sha <<< "$meta")
  current=$(jq -r .content <<< "$meta" | base64 -d)
fi
codeowners_pushed=0
if [ "$current" != "$desired" ]; then
  args=(-f "message=CODEOWNERS: $team (set by vending)" -f branch=main
        -f "content=$(printf '%s\n' "$desired" | base64 -w0)")
  [ -n "$current_sha" ] && args+=(-f "sha=$current_sha")
  gh api -X PUT "repos/$repo/contents/.github/CODEOWNERS" "${args[@]}" > /dev/null
  codeowners_pushed=1
  echo "  CODEOWNERS set to $team"
else
  echo "  CODEOWNERS already set"
fi

# 8. First deploy to dev. The template's initial commit was pushed before the
#    variables above existed, so its deploy-dev run skipped itself. Run it now,
#    once: if dev was ever deployed (a re-run of vending), leave it alone. A
#    CODEOWNERS commit above is a push to main and already starts deploy-dev.
if [ "$codeowners_pushed" = 1 ]; then
  echo "  deploy-dev started by the CODEOWNERS commit"
elif ! gh api "repos/$repo/contents/.github/workflows/deploy-dev.yml" --silent 2>/dev/null; then
  echo "::warning::$repo has no deploy-dev.yml (older template): first deploy skipped"
elif [ -n "$(gh run list --repo "$repo" --workflow deploy-dev.yml --status success --limit 1 --json databaseId --jq '.[].databaseId')" ]; then
  echo "  dev already deployed"
else
  gh workflow run deploy-dev.yml --repo "$repo" --ref main
  echo "  first deploy to dev started"
fi

echo "  done"
