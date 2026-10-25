# platform-vending

Turns a reviewed record into a ready-to-use project: its Azure resource groups,
identities, OIDC trust and roles, and its GitHub repo, environments and variables.
It also holds tier 0 (the one-off bootstrap everything else stands on) and the
per-department Azure preparation.

## The three layers

| Layer | When | Who runs it | What it creates |
|---|---|---|---|
| Tier 0 | Once | A subscription Owner, by hand (central IT at the company) | Custom roles, `id-vending`, `id-platform-plan` (`bootstrap/tier0.bicep`) |
| Department | Once per department | Phase 1: by hand. Phase 2: vending | RGs and deploy identities of the department (`infra/department.bicep`), then its base through a PR in platform-shared |
| Project | Once per app | Vending, on merge of `projects/<app>.yaml` | RGs, identities, roles, repo (`infra/project.bicep`, `scripts/configure-repo.sh`) |

Each layer can only give less than it has:

```
Owner (IT)          creates tier 0
  id-vending        creates department and app identities; may assign only the roles listed in tier0.bicep
    id-<dept>-platform-<env>   Contributor on rg-<dept>-platform-<env>: builds the department base
    id-<app>-<env>-deploy      Contributor on rg-<app>-<env>: builds the app
    id-<app>-<env>-runtime     data roles on rg-<app>-<env>: runs the app
```

No pipeline identity can grant roles, except `id-vending`, and only from its list.
Every identity lives outside the scope it can write to, so it cannot change who it
trusts: app and department identities in their own `*-identities` resource group,
the platform identities in `rg-platform-identities`.

## Identities

| Identity | Trusts (OIDC subject) | Can do |
|---|---|---|
| `id-vending` | `platform-vending`, environment `vending` | Contributor on the subscription; assign the listed roles to service principals |
| `id-platform-plan` | `platform-shared`, `pull_request` | What-If Reader on every department's platform RGs |
| `id-<dept>-platform-<env>` | `platform-shared`, environment `<dept>-<env>` | Contributor on `rg-<dept>-platform-<env>` |
| `id-<app>-<env>-plan` | app repo, `pull_request` | What-If Reader on the app's RG, environment and runtime identity |
| `id-<app>-<env>-deploy` | app repo, environment `<env>` | Contributor on `rg-<app>-<env>`, Joiner on its department's environment, AcrPush (dev only) |
| `id-<app>-<env>-runtime` | none (Azure-issued) | AcrPull; Key Vault Secrets User and storage data roles on `rg-<app>-<env>` |

Custom roles (tier 0, fixed GUIDs, also in `platform.yaml`):

- **Container Apps Environment Joiner**: read and join one Container Apps
  environment. Lets an app deploy into its department's shared environment
  without being able to change it. One definition for all departments; it is
  assigned on one environment, which is what isolates departments.
- **What-If Reader**: read configuration and run what-if, but no log queries and
  no image pulls. For identities that run pull request code, which is unreviewed.

Not covered: Entra app registrations (user sign-in, Graph or Dynamics APIs). They
need Graph permissions no pipeline has; keep them documented per project.

## Tier 0 (once)

Azure, as subscription Owner:

1. Register the resource providers: `Microsoft.ManagedIdentity`,
   `Microsoft.OperationalInsights`, `Microsoft.App`, `Microsoft.ContainerRegistry`,
   `Microsoft.KeyVault`, `Microsoft.Insights` (for the alert), and
   `Microsoft.Storage` / `Microsoft.DBforPostgreSQL` when an app needs them.
2. Review and deploy tier 0:
   ```
   az deployment sub what-if -l swedencentral -f bootstrap/tier0.bicep -p bootstrap/tier0.bicepparam
   az deployment sub create  -l swedencentral -f bootstrap/tier0.bicep -p bootstrap/tier0.bicepparam
   ```
   Outputs: `vendingClientId`, `platformPlanClientId`, `platformPlanPrincipalId`.

GitHub, as org owner:

1. Create the vending GitHub App on the org (Administration, Variables,
   Environments, Custom properties: read/write; Members, Contents, Actions: read), install
   it on the org, generate a private key.
2. In this repo: environment `vending` (required reviewers: the platform team,
   deployment branches: `main`) with variables `VENDING_CLIENT_ID`,
   `VENDING_APP_ID` and secret `VENDING_APP_PRIVATE_KEY`; repo variables
   `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
3. In platform-shared: repo variables `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`,
   `AZURE_PLAN_CLIENT_ID` (= `platformPlanClientId`).
4. Rulesets on `main` of every repo: pull request required, checks must pass.
5. Mark `tmpl-webapp-bicep` as a template repository.

## Adding a department (phase 1)

1. Azure: `infra/department.bicep` with the department name, the platform-shared
   OIDC subject prefix (`gh api repos/<org>/platform-shared/actions/oidc/customization/sub --jq .sub_claim_prefix`),
   `platformPlanPrincipalId` and the What-If Reader GUID. Outputs the client
   ID of each environment's deploy identity.
2. GitHub, in platform-shared: environments `<dept>-dev` and `<dept>-prod`, each
   with variable `AZURE_CLIENT_ID`, deployment branches `main`; on `-prod`,
   required reviewers = the department's team.
3. platform-shared pull request: `infra/teams/<dept>.{dev,prod}.bicepparam` and a
   CODEOWNERS line. The PR shows the what-if; merging deploys dev, then prod after
   approval.
4. This repo, pull request: the department under `departments:` in
   `platform.yaml` (names follow the convention shown there).

Phase 2 moves steps 1, 2 and 4 into vending: a reviewed `departments/<dept>.yaml`
runs `department.bicep` and configures the platform-shared environments.

## Vending a project

1. A team opens an issue with the **New project** form.
2. The platform team opens a pull request adding `projects/<name>.yaml`. The
   pull request checks the record offline (`scripts/validate-project.sh`); right
   before vending, the same script checks online that the teams exist and that
   the repo is free (or was made from the template), before anything is created.
   Reviewing it is the approval.
3. On merge, `vend-project.yml` waits for approval on the `vending` environment,
   then runs `infra/project.bicep` (Azure) and `scripts/configure-repo.sh`
   (GitHub: repo from the template, team access, environments, variables).
   Environment `dev` accepts `main` and `v*` tags; `prod` accepts `v*` tags only
   and needs approval. Rulesets make `v*` tags creatable by the owning team only,
   and immutable.
4. The new repo's first push to `main` deploys to dev.

Re-running a project changes nothing. To re-run one by hand, use **Run workflow**
with `projects/<name>.yaml`.

## Security notes

- All actions are pinned by commit SHA; Dependabot proposes updates as PRs.
- **Accepted risk (test setup):** `id-vending` lives in the subscription where it
  is Contributor, so a stolen vending token could add a federated credential to
  `id-vending` itself. Mitigated by SHA pinning, the `vending` approval and the
  alert on federated credential changes. At the company, deploy tier 0's
  `rg-platform-identities` in IT's management subscription instead.
- `id-vending` may assign Contributor (needed for every deploy identity), so a
  stolen token could still give some service principal Contributor. It cannot
  give anyone the right to grant roles, and cannot edit the custom roles
  (Contributor excludes `Microsoft.Authorization/*/write`).
- Open: every app's dev deploy identity has AcrPush on the whole department
  registry, so it could overwrite another app's image tags. Fix later with
  repository-scoped permissions or deploying by digest.

## Not handled yet

- Retiring a project or a department (deleting a record does nothing).
- Template updates reaching already vended repos.
- Rewriting CODEOWNERS of a vended repo with its team.

## OIDC subjects

GitHub may put the repo's numeric IDs in the token subject
(`repo:<org>@<orgId>/<repo>@<repoId>:...`, the default for new repos) instead
of plain names. The IDs never change, so a deleted and recreated repo with the
same name does not inherit the trust. Every federated credential here is built
from the prefix GitHub reports for the repo
(`gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix`),
so it works with either format. That is why vending creates the app repo first
and its Azure identities second.
