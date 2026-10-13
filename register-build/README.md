# `register-build` action

Use this when you build and push a component's image yourself (Buildx or Bake, Bazel, Nix, a vendor build service, multi-arch builds) instead of letting DeployTrack's dev CI build it. One step after your own push:

```yaml
permissions:
  contents: read
  packages: write   # the retag pushes a tag with GITHUB_TOKEN

steps:
  # ... build and push, e.g. docker/build-push-action with id: push
  - uses: Blackbard22/deploytrack-workflows/register-build@v1
    with:
      tracker_url: ${{ vars.TRACKER_URL }}
      token: ${{ secrets.CICD_WEBHOOK_SECRET }}
      component: backend
      image: ghcr.io/org/app@${{ steps.push.outputs.digest }}
```

What it does:

1. Resolves `image` to `repo@sha256:<digest>`. A digest reference is used as is; a `repo:tag` is read from the registry (`docker buildx imagetools inspect`).
2. Calls DeployTrack's `POST /api/builds/import`. DeployTrack checks the image and allocates the version and build number exactly as a normal build does.
3. Retags the image **inside the registry** to DeployTrack's version tag, `repo:<version>-build<N>`, with `docker buildx imagetools create`. Nothing is pulled or rebuilt, and a multi-arch manifest list keeps its digest. The action then checks that the new tag serves the same digest.
4. Reports the result back to DeployTrack. On success the build counts as deployed to the first pipeline stage (`dev`), so it promotes like any other build and its tickets are linked from the commit range. On failure the build is marked failed with the error, and the job fails.
5. Writes the version, image tag, digest and build id to the job summary.

Re-running the same image and commit returns the existing build: nothing is allocated twice, and an image that is already imported is not retagged again. A failed import is retried by running the action again.

Any non-2xx answer from DeployTrack fails the job with DeployTrack's message, for example `DeployTrack rejected the import (HTTP 422): component is managed by DeployTrack CI`.

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `tracker_url` | yes | | DeployTrack API base URL |
| `token` | yes | | `CICD_WEBHOOK_SECRET` |
| `component` | yes | | Component name; it must be in **external** build mode (an admin sets it in the project workspace). A component DeployTrack doesn't know yet is created as external on its first import. |
| `image` | yes | | `repo@sha256:…` preferred; `repo:tag` is resolved to its digest |
| `commit_sha` | no | `github.sha` | Commit the image was built from |
| `branch` | no | `github.ref_name` | |
| `repository` | no | `github.repository` | Enrolled repo that identifies the DeployTrack project |
| `project_id` | no | | If given, it must be the repository's project |
| `registry_username` | no | `github.actor` | |
| `registry_token` | no | `github.token` | Needs `packages: write`; use a PAT for a registry outside the repo's org |
| `build_id` | no | | Retag-only mode, used by `promote.yml` (below) |

Outputs: `build_id`, `version`, `docker_image`, `digest`, `status` (`built` or `failed`).

## Rules

- **Push to the component's own image repository** (its `image_repository` in DeployTrack, e.g. `ghcr.io/org/app-backend`). DeployTrack refuses an image from any other repository and retags inside that one.
- **`commit_sha` must be the commit the image was built from.** Ticket links come from the commit range since the component's previous build.
- **Don't push DeployTrack's tags yourself**: version tags (`1.4.0-build2`) and environment tags (`dev`, `staging`, `production`, …). DeployTrack refuses them as input; pass the digest of your own push.

## One-time setup

- The repo is enrolled through the DeployTrack GitHub App (it already has `CICD_WEBHOOK_SECRET` and `TRACKER_URL`).
- The component is set to **External build** in the project workspace, with its image repository.
- The job grants `packages: write` to `GITHUB_TOKEN`, or passes a PAT as `registry_token` for a registry outside the repo's org.

## Runner requirements

`bash`, `curl`, `jq` and `docker buildx` (GitHub-hosted runners have all of them). On a self-hosted Windows runner, run [`scripts/setup-tools.ps1`](../scripts/setup-tools.ps1) first for Git Bash and `jq`; Docker Desktop ships `buildx`. The action logs in with an isolated `DOCKER_CONFIG` under `RUNNER_TEMP` and removes it when it finishes.

## Retag-only mode

When you import from the DeployTrack UI instead, DeployTrack dispatches the repo's `promote.yml` caller with `environment` set to the first pipeline stage. The reusable `promote.yml` then runs its `import` job, which calls this action with `build_id`: it fetches the pending import (`GET /api/builds/{id}/import`), retags and reports back. For a build that isn't a pending import (a normal CI build, or one already imported) there is nothing to do and the job succeeds, as dispatching the first stage did before.

Tests: [`scripts/tests/register-build.tests.sh`](../scripts/tests/register-build.tests.sh), with fake `curl` and `docker`.
