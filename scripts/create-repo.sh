#!/usr/bin/env bash
# First GitHub step of vending one project: create the repo from the template
# (if missing) and print its OIDC subject prefix, e.g.
#   repo:tiago-platform-lab@346922760/my-app@1431112345
# The repo must exist before its Azure identities: with GitHub's immutable
# subjects the prefix holds the repo's numeric ID, so the federated credentials
# can only be written once the repo is created. Safe to re-run.
#
# Usage: create-repo.sh <projects/x.yaml> <platform.yaml>
# Needs: GH_TOKEN (vending GitHub App). The App needs, besides the permissions
# in configure-repo.sh, Actions (r) to read the subject prefix.
set -euo pipefail

project=$1
platform=$2

repo=$(yq '.repo' "$project")
template=$(yq '.github.template' "$platform")
visibility=$(yq '.github.visibility // "private"' "$platform")

# Template files only; settings come in configure-repo.sh. The new repo's own
# deploy workflow skips itself until vending sets APP_NAME.
if gh repo view "$repo" > /dev/null 2>&1; then
  echo "repo $repo exists" >&2
else
  gh repo create "$repo" --template "$template" "--$visibility" >&2
fi

# Whatever format the org or repo uses (immutable IDs or plain names), this is
# exactly what GitHub will put in the tokens.
gh api "repos/$repo/actions/oidc/customization/sub" --jq .sub_claim_prefix
