# `.deploytrack.yaml` specification (v1)

Public contract for the per-repo config file. The GitHub App (`ResolveConfig` / `RegisterProject`) and the reusable workflows (`resolve-config.sh`) both implement this document. Parsers do **not** read `SPEC.md` at runtime.

Workflow tag `@v1` accepts schema `version: 1`. Adding optional fields that keep existing files valid stays `@v1`. Breaking schema changes cut `@v2` and a new schema `version`.

There is no compatibility path for older scaffold shapes (`components: auto`, comma-separated component strings, root `image_repository`).

---

## Example

Explicit list:

```yaml
version: 1

branches:
  - dev
  - staging
  - production

components:
  - name: backend
    path: ./backend
  - name: frontend
    path: ./frontend

approvals:
  dev: qa
  staging: client
```

`dockerfile` and `image_suffix` may be omitted; they default to `Dockerfile` and `name`. `approvals` may be omitted; see [Approval gates](#approval-gates) for the defaults.

Infer from Compose (same resolution as a missing `components` list):

```yaml
version: 1

branches:
  - dev
  - staging
  - production

components:
  infer: true
```

---

## Fields

| Field | Type | Required | Default / notes |
|---|---|---|---|
| `version` | integer | no | Schema version. Omitted or `0` means `1`. `@v1` workflows accept `1`. |
| `branches` | list of strings | no | If present and non-empty, **replaces** the default `["dev", "production"]`. Order is the pipeline (see below). |
| `components` | list of objects, or mapping | no | List: **replaces** the default. Mapping with `infer: true`: Compose inference (see below). Empty/omitted: same as missing `components`. |
| `components.infer` | boolean | no | When `true`, ignore any component list and pull services from Compose exactly as if `components` were missing. |
| `components[].name` | string | no | If omitted, derived from `path` (`./api` → `api`; `.` → `app`). A list item that is a bare string is treated as `name` only; `path` still defaults to `.`, not `./<name>`. |
| `components[].path` | string | no | Build context. Default `.`. |
| `components[].dockerfile` | string | no | Default `Dockerfile`. Relative to `path` (`path: ./backend` + `dockerfile: Dockerfile` → `./backend/Dockerfile`). CI: `docker build -f {path}/{dockerfile} {path}`. |
| `components[].image_suffix` | string | no | Default = `name` (after name is resolved). |
| `approvals` | mapping of branch → `qa` \| `client` \| `none` | no | Approval gate per pipeline stage. If present and non-empty, **replaces** the default gates (see [Approval gates](#approval-gates)). Read by the App only; the workflows ignore it. |
| `build.shared_changes` | `all` \| `none` | no | Default `all`. What a change to files outside **every** component's `path` rebuilds: every component, or nothing. See [Detect and build](#detect-and-build). |
| `build.ignore` | list of strings | no | Default `["*.md", "docs/", ".github/"]`. If present, **replaces** the default. Path patterns that never trigger a build; `*` matches any characters including `/`, and a pattern ending in `/` matches everything under that folder. |

`image_repo_prefix` is not a field in this file. The App writes it as a repo variable at enrollment (`IMAGE_REPO_PREFIX`, typically `ghcr.io/<owner>/<repo>`); callers pass it into the reusable workflow. Images are always `{image_repo_prefix}-{image_suffix}`.

Unknown keys at the top level and inside each component are **ignored** (forward-compatible). Wrong types for known fields are still errors.

---

## Compose inference

Used when **any** of these is true:

- there is no `.deploytrack.yaml`
- `components` is omitted or empty
- `components.infer` is `true`

**File lookup.** First file that exists at the **repo root** wins; do not merge. Order:

1. `docker-compose.yml`
2. `docker-compose.yaml`
3. `compose.yml`
4. `compose.yaml`

**Which services.** Only entries under `services:` that have a `build:` key. Skip `image:`-only services (postgres, redis, …). Ignore `include:`, profiles, `build.target`, `build.args`, and other Compose knobs in v1.

**`build:` → component (string and mapping).** Service key becomes `name` and `image_suffix`.

| Compose | Component |
|---|---|
| `build: ./api` (string) | `path: ./api`, `dockerfile: Dockerfile` |
| `build.context` | `path` (default `.`) |
| `build.dockerfile` | `dockerfile` (default `Dockerfile`, relative to `path`) |

```yaml
services:
  api:
    build: ./api
  web:
    build:
      context: ./frontend
      dockerfile: Dockerfile.prod
  db:
    image: postgres:16
```

becomes two components: `api` (`./api` / `Dockerfile`) and `web` (`./frontend` / `Dockerfile.prod`). `db` is skipped.

**If that yields nothing** (no Compose file, or no service with `build:`): one component, **only if `./Dockerfile` exists**

```yaml
name: app
path: .
dockerfile: Dockerfile
image_suffix: app
```

With no root `Dockerfile` either, the repo has **no components**. That is a valid state, not an error: a new or empty repo has nothing to build yet (see [Detect and build](#detect-and-build)).

Default `branches` when they are also omitted: `["dev", "production"]`. A file with `components.infer: true` can still set `branches` explicitly; only the component list is inferred.

Do not combine `infer: true` with a component list. If both appear, `infer: true` wins and the list is ignored.

---

## Resolution rules (file present)

- **Replace, don’t merge.** A non-empty `components` **list** or `branches` list fully replaces the corresponding default. Omitted or empty lists keep the default for that field only. `components.infer: true` is not a list; it runs Compose inference instead.
- **Name from path.** Missing `name` → last non-`.` path segment; `path: .` → `app`. A bare string in the list is `name` only; `path` stays `.` unless set.
- **Dockerfile under path.** `dockerfile` is relative to `path`.
- **Duplicate names allowed.** Two entries with the same `name` are two matrix legs that report the same tracker component name.
- **Images.** `{image_repo_prefix}-{image_suffix}`.
- **Pipeline.** `branches` order is the promotion pipeline. Index `0` is the CI/build branch; every later entry is a promote target. A one-element list is CI-only (no promote).

---

## Detect and build

`dev-ci.yml` runs in three stages, all on a `self-hosted` runner. `promote.yml` does the same for its `setup` and `promote` jobs. The workflows only run on self-hosted runners: nothing uses a GitHub-hosted runner, so private repos in an org without hosted-runner minutes still run.

**Runner requirements:** a Windows self-hosted runner with PowerShell, Docker and [Git for Windows](https://gitforwindows.org/). `detect` and promote's `setup` are bash steps, so they run in Git Bash; [`scripts/setup-tools.ps1`](scripts/setup-tools.ps1) puts Git Bash first on `PATH` (ahead of WSL's `System32\bash.exe`) and installs pinned, checksum-verified `jq` and `yq` into the runner tool cache on first use.

**`baselines`** (on the build runner) asks DeployTrack, via `GET /api/projects/{id}/build-baselines`, which commit each component was last built from: its newest build with a successful deploy to the first pipeline stage. If the call fails, every component builds.

**`detect`** (on the build runner, in Git Bash) resolves the components with the rules above (`scripts/resolve-config.sh`), then checks that each one can be built (`scripts/check-components.sh`): the build context `path` must be a directory and `{path}/{dockerfile}` must exist.

- **A declared component without its Dockerfile fails the whole run.** This applies to components from `.deploytrack.yaml` and from Compose `build:` services. Every missing file is reported as an error, nothing is allocated in DeployTrack, and no component is built until it is fixed.
- **No components is a success.** The run ends green with a summary saying there is nothing to build, and the `build` job is skipped.

Then `scripts/select-changed.sh` keeps only the components that need a build. It compares `git diff <baseline> HEAD`, minus `build.ignore`, with each component's `path`. A component builds when any of these is true:

| Reason | Example |
|---|---|
| Its folder changed since its baseline | `frontend/src/app.ts` edited → `frontend` builds, `backend` does not |
| A shared file changed and `build.shared_changes` is `all` (default) | `package-lock.json` at the root → every component builds |
| It has never built, or its baseline commit is not in the history | first push, or after a force-push |
| A new version was picked for it in DeployTrack | the Next release panel → that component builds even if unchanged |
| It was forced | see below |

A component with `path: .` owns the whole repo, so any non-ignored change builds it. Unchanged components are listed in the run summary with the commit they were last built from. Renames count for both the old and the new folder.

**Forcing a build.** The caller's `workflow_dispatch` takes a `build` input, passed to `dev-ci.yml` as `force_components`: blank means changed components only, `all` builds everything, and a comma list (`frontend,backend`) builds those components as well as any that changed. DeployTrack's **Build** button dispatches the caller with that input (`POST /api/projects/{id}/builds/dispatch`). Callers enrolled before this input existed need it added to `.github/workflows/deploytrack.yml` by hand.

**`build`** runs one matrix leg per selected component, as before.

---

## Production releases

When `promote.yml` promotes a build to the **last** entry in `branches` (production), it also publishes a GitHub Release, so the repo's Releases page always shows what production runs (`scripts/publish-release.ps1`).

| | Single-component repo | Repo with several components |
|---|---|---|
| Tag | `v1.4.0` | `backend-v1.4.0` |
| Name | `1.4.0` | `backend 1.4.0` |

- **Where the tag points:** the build's commit, not the tip of the environment branch.
- **Notes:** the production image and environment tag, build number, commit, DeployTrack build id and a link to the promote run, followed by GitHub's generated notes since the previous tag of the same component.
- **Latest:** every production promote marks its release Latest, so in a repo with several components the most recently promoted one is Latest.
- **Same version again:** if a later build of the same version reaches production, the tag is moved to its commit and the notes gain a line saying production now runs that build. Re-running a promote changes nothing but the Latest flag.
- **Failures don't undo the promote:** the image is already retagged and the deploy recorded. A Releases error shows as a warning in the run summary.

The caller's `promote.yml` already grants `contents: write`, which this needs. Promotes to any earlier stage publish nothing.

**Registration.** DeployTrack registers a component the first time CI allocates a build for it, whichever branch it first appears on. The App also registers the components it resolves from the default branch at enrollment, on config sync and on reconcile. A project with no registered components shows "no buildable components" in DeployTrack.

---

## Approval gates

Each entry in `branches` is a pipeline stage (a DeployTrack environment, named after the branch in lower case). A stage can carry one approval gate, owned by a role: `qa` or `client`.

**The source stage owns the gate.** A gate on stage X means the build's successful deploy in X must be approved by that role before the build can be promoted to the next stage. Rejecting it stops the build. CI deploys to the first stage are never gated; the first stage's gate guards the hop out of it.

```yaml
branches: [dev, staging, production]
approvals:
  dev: qa          # QA approves the dev deploy before dev → staging
  staging: client  # the client approves the staging deploy before staging → production
```

**Defaults** apply when `approvals` is omitted or empty. They depend on position in `branches`, not on branch names:

| Stages | Default gates |
|---|---|
| 1 | none (CI only) |
| 2, including the default `["dev", "production"]` | none |
| 3 or more | `qa` on the first stage, `client` on the stage before the last, `qa` on every stage in between, none on the last |

So `[dev, staging, production]` defaults to `dev: qa`, `staging: client`, and `[dev, test, uat, live]` to `dev: qa`, `test: qa`, `uat: client`.

**Rules**

- **Replace, don't merge.** A non-empty `approvals` map is the complete set of gates. Stages it does not list have no gate, whatever the defaults would have given them.
- **`none`** means no gate. It is how a repo opts out of the defaults: `approvals: {dev: none}` on a three-stage pipeline leaves every hop ungated.
- **Two stages are ungated unless you say otherwise.** Add `approvals: {dev: qa}` to gate `dev → production`.
- **Keys** must be entries of the resolved `branches`; values must be `qa`, `client` or `none`. Both are case-insensitive. Anything else is a config error: enrollment or the config sync fails and the gates already registered stay in place.
- **Last stage.** A gate on the last stage is accepted but blocks nothing, because there is no next stage. It is a sign-off record only.
- **Who can promote.** Promoting out of a gated stage needs that stage's role on the project; promoting out of an ungated stage needs only project access.

**Changing the file.** The App reads `.deploytrack.yaml` from the repo's **default branch**. It registers the pipeline at enrollment, and again on every push to the default branch that adds, edits or deletes the file (`SyncConfigJob`):

- Changed gates apply to the next approval or promote; approvals already recorded are kept.
- A branch added to `branches` is created from the default branch tip and becomes a tracker environment.
- A branch removed from `branches` stops being a tracker environment. The git branch itself is left alone, and past deployments keep their environment name.
- Deleting the file returns the repo to the default branches and the default gates.
- Changing the first (CI) branch is not applied to the enrolled repo's caller workflow, which still triggers on the original branch; edit `.github/workflows/deploytrack.yml` by hand.

---

## Compatibility

| Workflow tag | Schema `version` |
|---|---|
| `@v1` | `1` (including omitted `version`) |

---

## Implementation status

App and [`scripts/resolve-config.sh`](scripts/resolve-config.sh) implement Compose inference from the first repo-root Compose file (`docker-compose.yml` → `docker-compose.yaml` → `compose.yml` → `compose.yaml`). Missing yaml, empty or omitted components, and `components.infer: true` expand to the same explicit list (or the `app` fallback when `./Dockerfile` exists, else no components). [`scripts/check-components.sh`](scripts/check-components.sh) is the `detect` job's Dockerfile check; [`scripts/select-changed.sh`](scripts/select-changed.sh) picks the components that changed. All three are covered by `scripts/tests/run.sh`, and [`scripts/publish-release.ps1`](scripts/publish-release.ps1) (production GitHub Releases) by `scripts/tests/publish-release.tests.ps1`; `test-scripts.yml` runs both on changes. App org defaults are `["dev", "production"]`. Reusable [`promote.yml`](.github/workflows/promote.yml) retags one `build_id` to an `environment` input; a missing or CI-only (index 0) target in `branches` is a no-op. Enrollment writes a thin `workflow_dispatch` caller so `trigger-promote` can dispatch it.

The App resolves `approvals` into per-stage gates (`ResolveEnvironments`) and sends them to the tracker as `environments` in `RegisterProject`; the tracker removes environments that are no longer listed. `SyncConfigJob` re-registers on pushes to the default branch that touch `.deploytrack.yaml`. `resolve-config.sh` and the reusable workflows ignore `approvals`; gates are enforced by the tracker when a promote is triggered or recorded.
