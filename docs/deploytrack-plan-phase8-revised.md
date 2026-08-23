# Phase 8 (revised) — `.deploytrack.yaml` spec + config-generic reusable workflows

Replaces the original Phase 8. The original stood up a central workflows repo but treated the three workflows as static and never specified `.deploytrack.yaml` as a real, implemented artifact. This revision does both: it makes `.deploytrack.yaml` the versioned contract that drives what gets built and tracked, and it makes the three workflows read that contract at runtime so per-repo differences (component count, branches, build context) need no per-repo workflow edits.

Depends on: Phase 5 (schema carries `project_components` / `project_environments`), Phase 6 (App registers those from the resolved config), Phase 7 (OIDC, since the workflows authenticate with it).

---

## 8.0 — Design decision: where config lives at run time

`.deploytrack.yaml` lives in each app repo, but a `workflow_call` reusable workflow is defined before it knows which repo calls it. Two mechanisms bridge that gap, and this phase uses a deliberate hybrid:

- **App-baked (repo variables):** stable, rarely-changing values — tracker URL, project id, image-repo prefix — are parsed by the App at enrollment and written as repo variables. Changed only when the App re-runs (`SyncConfigJob` on a `.deploytrack.yaml` change).
- **Runtime-parsed (matrix):** the *component list* and per-component build settings are read from the checked-out `.deploytrack.yaml` by a setup job inside the workflow, which emits a build matrix. Always current — adding a component is a one-line commit that takes effect on the next push, no re-enrollment.

Rationale: infrastructure pointers should be stable and App-owned; what-to-build should be developer-owned and immediate. Splitting them along that line is what keeps the workflows generic without making every config change a round-trip through the App.

---

## 8.1 — Specify `.deploytrack.yaml` as a versioned contract

This is a public interface every enrolled repo depends on — treat it like an API contract, not just a Go struct. Write it as a standalone spec doc in the workflows repo (`SPEC.md`), so both the App and the workflows read against the same definition.

**Schema (v1):**
```yaml
version: 1                    # schema version, for forward-compat parsing

branches:                     # the pipeline; order defines promotion sequence
  - dev
  - staging
  - production

components:                   # what gets built + tracked; drives the matrix
  - name: backend
    path: .                   # build context (Dockerfile dir)
    dockerfile: Dockerfile    # optional, defaults to <path>/Dockerfile
    image_suffix: backend     # appended to the image repo prefix
  - name: frontend
    path: ./web
    dockerfile: Dockerfile
    image_suffix: frontend

# optional overrides
image_repository: ""          # empty = derive <prefix>-<image_suffix>
```

**Field rules to specify explicitly in SPEC.md:**
- [ ] `components` is a list of arbitrary length — one entry (single service), two (the old backend/frontend), or many (monorepo). No hardcoded names anywhere.
- [ ] `branches` order *is* the promotion pipeline — the first is the build/CI branch, each subsequent one a promotion target. A repo omitting `staging` (`[dev, production]`) is valid and the promote step must honor it (the Phase 5 pipeline-from-data refactor is what makes this real).
- [ ] Every field is optional except `version`; missing fields fall back to org defaults (`DefaultConfig()`), so a repo with no `.deploytrack.yaml` at all still works.
- [ ] Unknown fields are ignored, not fatal — forward-compatible parsing (edge cases doc 1.11).

**Implementation:**
- [ ] Extend `internal/githubapi/repoconfig.go`'s `RepoConfig` struct to the full schema above (the scaffold has a partial version) — `components` becomes a slice of structs, not the current `Components string`
- [ ] Update `ResolveConfig` to merge the component list and branch list correctly (repo list replaces default list when present)
- [ ] This same struct is what Phase 6's `RegisterProject` sends to the backend to create `project_components` / `project_environments` — one parse, two consumers

---

## 8.2 — Create and populate the workflows repo

- [ ] Create `Blackbard22/deploytrack-workflows` with `SPEC.md` (8.1) and three `workflow_call` files: `dev-ci.yml`, `staging-promote.yml`, `production-promote.yml`
- [ ] Add `permissions: id-token: write` to each for the OIDC flow (Phase 7)

---

## 8.3 — Make `dev-ci.yml` config-generic (the build workflow)

This is where the matrix-from-config pattern lives. Structure it as two jobs: a setup job that parses the config into a matrix, and a build job that fans out over it.

**Setup job:**
- [ ] Checks out the caller repo (so `.deploytrack.yaml` is present)
- [ ] Parses `.deploytrack.yaml` → emits the `components` list as a JSON matrix output (a few lines of `yq` or a tiny script). If the file is absent, emit the org-default matrix so behavior matches a repo with no config
- [ ] Emits the resolved branch list too, for the promote workflows to consume

**Build job (`needs: setup`, `strategy.matrix` from the setup output):**
- [ ] One matrix entry per component — no hardcoded backend/frontend jobs
- [ ] Each entry builds `${{ matrix.component.path }}` with `${{ matrix.component.dockerfile }}`, tags the image `<image_repo_prefix>-${{ matrix.component.image_suffix }}:<version>`
- [ ] Reports the build to DeployTrack per component (`POST /api/builds` with the component name), authenticating via OIDC (Phase 7)
- [ ] A single-component repo runs one matrix leg; a ten-component monorepo runs ten — same workflow file, zero edits

**Inputs the caller passes (stable, App-baked variables):**
- [ ] `tracker_url`, `project_id`, `image_repo_prefix` — from repo variables the App set at enrollment
- [ ] Everything variable (which components, which paths) comes from the runtime parse, not inputs

---

## 8.4 — Make the promote workflows config-generic

`staging-promote.yml` and `production-promote.yml` must not assume a fixed source/target pair — the pipeline is whatever `branches` says.

- [ ] Parameterize target environment as an `input` (`environment`), not hardcoded in the filename's logic — the App's `trigger-promote` dispatch passes which env to promote to
- [ ] The promote job re-tags / re-deploys the **same image** built on dev (no rebuild) for **every component** in the matrix — reuse the same setup-job matrix pattern as 8.3 so promote also fans out over the component list
- [ ] Guard: if the target environment isn't in the repo's resolved `branches`, the workflow no-ops with a clear message rather than failing — this is what makes a `[dev, production]` repo (no staging) safe when a staging-promote is somehow dispatched
- [ ] Report each component's deployment back via the cicd path → `EventProcessor` (per `ARCHITECTURE.md`), advancing the per-component release status

**Consolidation option worth considering:** because the promote logic is now identical except for the target env (an input), the two promote workflows can collapse into **one** `promote.yml` taking `environment` as input. Fewer files to version, and it naturally supports pipelines with more than two promotion targets (a repo with `[dev, staging, uat, production]` just dispatches promote three times with different `environment` values). The original "staging-promote / production-promote" split is a holdover from the two-fixed-stage assumption the Phase 5 refactor removed.

---

## 8.5 — Version the workflows

- [ ] Tag `v1`; callers pin `@v1`
- [ ] Policy: move the `v1` tag for backward-compatible changes (including SPEC.md additions that keep old configs valid), cut `@v2` for breaking schema changes
- [ ] A `@v1→@v2` bump is a one-line caller PR the App or a bulk script opens across repos
- [ ] Because SPEC.md is versioned alongside the workflows, a repo's `.deploytrack.yaml version:` and the workflow tag it calls stay coherent — document which schema versions each workflow tag accepts

---

## 8.6 — Wire the caller into enrollment

- [ ] Implement `renderWorkflowCaller()` in `internal/jobs/enroll_repo.go` to emit the caller file: the `uses:` reference plus the stable inputs (tracker url, project id, image prefix as variables)
- [ ] The caller stays ~6–10 lines and never needs editing when components change — because components are read at run time from `.deploytrack.yaml`, not baked into the caller
- [ ] Confirm the App still writes `.deploytrack.yaml` itself is **not** required — if the repo already has one, leave it; if not, the enrollment PR can optionally include a starter `.deploytrack.yaml` with the resolved defaults so the developer sees the contract explicitly and can edit it

**Checkpoint:** three test repos on the same `@v1` workflows — one single-component, one two-component, one three-component monorepo with a custom `path` — all build correctly with no per-repo workflow differences. Adding a fourth component to the monorepo's `.deploytrack.yaml` and pushing produces a fourth build on the next run, with no re-enrollment and no workflow edit. A repo whose `branches` omits `staging` promotes dev → production directly.
