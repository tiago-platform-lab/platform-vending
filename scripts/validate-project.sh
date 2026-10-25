#!/usr/bin/env bash
# Checks one project record before it is vended.
#
#   (default)  no network: the record is well formed and consistent with
#              platform.yaml. Runs on every pull request.
#   --online   needs GH_TOKEN (vending GitHub App): the teams exist, and the repo
#              either does not exist yet or was created from our template, so
#              vending never takes over a repo it did not create. Runs in the
#              vend job before anything is created, so a bad record fails early
#              instead of halfway.
#
# Usage: validate-project.sh <projects/x.yaml> <platform.yaml> [--online]
# Prints one ::error per problem and exits 1 if there is any.
set -euo pipefail

project=$1
platform=$2
mode=${3:-}

[ -f "$project" ] || { echo "::error::$project does not exist"; exit 1; }

errors=0
fail() { echo "::error file=$project::$*"; errors=$((errors + 1)); }
field() { yq "$1 // \"\"" "$project"; }

name=$(field .name)
repo=$(field .repo)
dept=$(field .department)
team=$(field .team)
approvers=$(field .prodApprovers)
owner=$(field .tags.owner)
cost_centre=$(field '.tags["cost-centre"]')
tag_dept=$(field .tags.dept)
org=$(yq '.github.org' "$platform")
template=$(yq '.github.template' "$platform")

# Name: it becomes the repo name and part of every Azure name (kv-<name>-prod
# must fit in 24 characters).
if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{1,14}[a-z0-9]$ ]]; then
  fail "name '$name': 3-16 characters, lowercase letters, digits and hyphens, not starting or ending with a hyphen"
fi
[ "$(basename "$project" .yaml)" = "$name" ] || fail "file name must be $name.yaml"
[ "$repo" = "$org/$name" ] || fail "repo must be $org/$name (got '$repo')"

# Department and environments must exist in platform.yaml.
if [ -z "$dept" ] || [ "$(yq ".departments.\"$dept\" // \"\"" "$platform")" = "" ]; then
  fail "department '$dept' is not in platform.yaml"
fi
envs=$(yq '.environments // [] | .[]' "$project")
[ -n "$envs" ] || fail "environments is empty"
grep -qx dev <<< "$envs" || fail "environments must include dev (prod releases promote the dev image)"
[ "$(sort <<< "$envs" | uniq -d)" = "" ] || fail "environments has duplicates"
while IFS= read -r e; do
  [ -n "$e" ] || continue
  case "$e" in dev | prod) ;; *) fail "unknown environment '$e' (dev or prod)"; continue ;; esac
  if [ -n "$dept" ] && [ "$(yq ".departments.\"$dept\".environments.$e // \"\"" "$platform")" = "" ]; then
    fail "department '$dept' has no $e environment in platform.yaml"
  fi
done <<< "$envs"

# Teams: GitHub team slugs.
for t in "$team" "$approvers"; do
  [[ "$t" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "team '$t' is not a GitHub team slug"
done

# Tags: who to ask and who pays.
[[ "$owner" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || fail "tags.owner '$owner' is not an email address"
[ -n "$cost_centre" ] || fail "tags.cost-centre is empty"
[ "$tag_dept" = "$dept" ] || fail "tags.dept '$tag_dept' must equal department '$dept'"

if [ "$mode" = "--online" ]; then
  for t in "$team" "$approvers"; do
    gh api "orgs/$org/teams/$t" --silent 2>/dev/null || fail "team '$t' does not exist in $org"
  done
  # An existing repo is fine only if vending made it (from our template), e.g.
  # a re-run. Any other repo with that name is left alone.
  if from=$(gh api "repos/$repo" --jq '.template_repository.full_name // ""' 2>/dev/null); then
    [ "$from" = "$template" ] || fail "repo $repo already exists and was not created from $template: vending will not take it over"
  fi
fi

if [ "$errors" -gt 0 ]; then
  echo "$project: $errors problem(s)"
  exit 1
fi
echo "$project: ok${mode:+ ($mode)}"
