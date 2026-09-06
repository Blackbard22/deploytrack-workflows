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
```

`dockerfile` and `image_suffix` may be omitted; they default to `Dockerfile` and `name`.

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

**If that yields nothing** (no Compose file, or no service with `build:`): one component

```yaml
name: app
path: .
dockerfile: Dockerfile
image_suffix: app
```

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

## Compatibility

| Workflow tag | Schema `version` |
|---|---|
| `@v1` | `1` (including omitted `version`) |

---

## Implementation status

App and [`scripts/resolve-config.sh`](scripts/resolve-config.sh) implement Compose inference from the first repo-root Compose file (`docker-compose.yml` → `docker-compose.yaml` → `compose.yml` → `compose.yaml`). Missing yaml, empty or omitted components, and `components.infer: true` expand to the same explicit list (or the `app` fallback). App org defaults are `["dev", "production"]`. Reusable [`promote.yml`](.github/workflows/promote.yml) retags one `build_id` to an `environment` input; a missing or CI-only (index 0) target in `branches` is a no-op. Enrollment writes a thin `workflow_dispatch` caller so `trigger-promote` can dispatch it. `SyncConfigJob` is still a stub.
