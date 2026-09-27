# DeployTrack GitHub App — implementation plan, phases 5 → end

Continues `deploytrack-github-app-plan.md` (phases 0–4). Those phases stood up the App in isolation: registration, webhook receipt, config resolution, and repo setup actions, now running on River. Phases 5 onward connect it to DeployTrack for real, reflect the schema redesign into the running backend, replace the shared CI secret, distribute the workflows, harden for scale, and roll out to the org.

Assumes phases 0–4 are done: App registered, webhook receiver verifying + enqueuing, `EnrollRepoJob` creating branches/PR/variables against a test repo, config resolution unit-tested.

Cross-references: `deploytrack-app-core-architecture.md` (components, libraries, data model), `deploytrack-app-edge-cases-retries.md` (failure modes), `deploytrack-schema-redesign.md` (new tables + backfill), and the backend `ARCHITECTURE.md` (existing services).

---



## Critical path (read first)

The phases are ordered by dependency, not by size. The one non-obvious ordering constraint: **Phase 5 (schema migration + service refactor) must land before Phase 6 (DeployTrack API integration)**, because the App's `RegisterProject` call writes `project_components` / `project_environments` / `app_enrollments` rows that don't exist until the migration runs, and the backend services that read them still speak free-text `component` until refactored. Everything else can flex.

Fastest path to a working end-to-end demo: 5 → 6 → 8 → 10 (partial, one repo), deferring OIDC (7) and hardening (9) until after you've seen a single repo go from enrollment through a tracked promote. OIDC and resilience are correctness/scale work, not "does it work at all" work.

---



## Phase 5 — Schema migration + backend service refactor

Goal: get the redesigned schema into the running backend so services stop speaking hardcoded `backend`/`frontend` and `staging`/`production`. `ARCHITECTURE.md` explicitly flags this as the gap: "Backend code still speaks free-text component + project columns until that migration is reflected in services/repos."

This is backend work (the `github.com/deploytrack/backend` module), not App-service work.

**5.1 — Apply the migrations**

- [ ] Write migration files for `project_components`, `project_environments`, `promotion_dispatches`, `app_installations`, `app_enrollments`, and the `projects.repo_id` / `owner_login` columns (from `deploytrack-schema-redesign.md`)
- [ ] Add `component_id` FK columns to `releases` and `builds`, and `project_environment_id` to `deployments` — nullable at first
- [ ] Keep the deprecated columns (`component` varchars, the two `*_promote_dispatched_at` timestamps, the project version-pref columns) in place — do not drop yet

**5.2 — Backfill (run once, before any service reads the new columns)**

- [ ] Execute the backfill checklist from the schema doc: two `project_components` per project from existing prefs; `component_id` on releases/builds by matching the old varchar; `project_environments` rows for staging (qa gate) + production (client gate); `promotion_dispatches` from the old timestamp columns
- [ ] The `projects.repo_id` / `owner_login` backfill needs a one-time script calling GitHub's API per `repo_url` — this data was never captured before, so it can't be pure SQL. Write this as a small standalone Go command using the App's GitHub client

**5.3 — Refactor the version-bump engine**

- [ ] `services/build_service.go` `resolveRelease`: read component identity from `project_components.component_id` instead of normalizing free-text to backend/frontend
- [ ] `project_service.go`: version-pref PATCH + previews now target `project_components` rows, arbitrary component count, not the two fixed project columns

**5.4 — Refactor promote / trigger to use** `project_environments`

- [ ] `services/deployment_service.go` `Promote` and `services/promote_trigger_service.go` `Trigger`: derive the pipeline (which env follows which, which gate applies) from `project_environments` ordered by `sort_order`, instead of the hardcoded "staging needs dev+QA, production needs staging+client"
- [ ] Stamp `promotion_dispatches` rows instead of the two fixed timestamp columns
- [ ] This is what makes a project with no `staging` env work — the promote logic reads the configured pipeline rather than assuming three fixed stages

**5.5 — Refactor approval gating**

- [ ] `services/approval_service.go`: read `requires_approval` / `approval_type` from the source env's `project_environments` row rather than the hardcoded "QA on dev, client on staging" rule
- [ ] The gate types (`qa`, `client`) stay, but which env triggers which gate is now data-driven

**5.6 — Refactor access control for per-project roles**

- [ ] `services/project_access.go`: use `project_members.role` scoped per project, instead of the current "admin/qa see all projects, client/developer see only their rows" global rule
- [ ] This is the fix for the "QA approves for 40 unrelated projects" bottleneck flagged early — QA/client can now be assigned per project
- [ ] Leave `source` (`manual` / `github_team` / `idp_sync`) defaulting to `manual`; the sync-from-GitHub-teams work is deferred to post-launch

**Checkpoint:** existing tracker flows (create build, promote, approve) work end to end against the new tables, for a project that has exactly the old backend+frontend / staging+production shape — proving the refactor is behavior-preserving before you rely on the new flexibility. Deprecated columns are now unread but still present.

**Dependency note:** do not drop the deprecated columns here. That's a follow-up migration in Phase 11 after a soak period, per the schema doc's backfill notes ("at least one full release cycle").

---



## Phase 6 — DeployTrack API integration (App ↔ backend)

Goal: wire the App's `RegisterProject` call to a real, idempotent backend endpoint, and handle installation lifecycle. This is the seam between the two services.

**6.1 — Build the register endpoint (backend side)**

- [ ] `POST /api/projects/register` (or extend the existing `POST /api/projects`) accepting `repo_id`, `owner_login`, `repo_name`, and the resolved config (branches, components)
- [ ] In one transaction: upsert the `projects` row (unique on `repo_id`), create `project_components` from the config's component list, create `project_environments` from the config's branches + gate settings, create the `app_enrollments` row
- [ ] Idempotent: calling twice for the same `repo_id` updates rather than duplicating — enforced by the unique constraint on `projects.repo_id` and `app_enrollments.repo_id`
- [ ] This endpoint is machine-only; gate it behind the same auth the App uses (see Phase 7 — until then, the existing CICD secret path)

**6.2 — Wire the App client (App side)**

- [ ] Implement `internal/deploytrack/client.go` `RegisterProject` — the scaffold stub — to call 6.1 and return `project_id`
- [ ] Confirm `EnrollRepoJob.Work()`'s ordering (fetch config → resolve → branches → PR → register → variables) still holds; register now returns the real `project_id` used for the `TRACKER_PROJECT_ID` variable
- [ ] Populate `app_enrollments` state transitions: `pending` on job start, `enrolled` on success, `failed` on discard (ties into the Phase 2 failure/retry state machine)

**6.3 — Installation lifecycle**

- [ ] Handle `installation` webhook events (created / deleted / suspend / unsuspend) → write/update `app_installations`, set `suspended_at` when uninstalled or permissions revoked (edge cases doc 1.8)
- [ ] Handle `repository.renamed` → update `app_enrollments.repo_name` and `projects.repo_url` for the matching `repo_id` (this is the rename-fragility fix — `repo_id` is stable, the cached name/url follow it)

**Checkpoint:** creating a test repo results in a real `projects` row plus its `project_components` / `project_environments` / `app_enrollments`, with the correct `project_id` flowing into the repo's `TRACKER_PROJECT_ID` variable. Renaming the repo updates the cached name without breaking the link.

---



## Phase 7 — OIDC trust (retire `CICD_WEBHOOK_SECRET`)

Goal: replace the single shared CI secret with per-run GitHub Actions OIDC tokens. This is the highest-leverage security change — it removes the one static secret that every enrolled repo would otherwise hold.

Important distinction: the backend already validates **Keycloak** OIDC for *human* users (`middleware/keycloak.go`). This phase adds validation of **GitHub Actions** OIDC for *machine* CI calls — a different issuer, different JWKS, replacing the `CICD_WEBHOOK_SECRET` bearer in `RequireJWTOrCICD`.

**7.1 — Backend: validate GitHub Actions OIDC tokens**

- [ ] Add a validator using `golang-jwt/jwt/v5` + `MicahParks/keyfunc/v3` to fetch and cache GitHub's OIDC JWKS (rotating keys — don't hardcode)
- [ ] Validate issuer (`https://token.actions.githubusercontent.com`), audience (a value you choose, set via `GITHUB_OIDC_AUDIENCE`), and signature
- [ ] Validate claims against the target project: the token's `repository` / `repository_id` claim must match the `projects.repo_id` for the resource being written; optionally check `ref` / `workflow`
- [ ] Set `golang-jwt` leeway for clock skew (edge cases doc 1.10)

**7.2 — Backend: extend the machine auth wrapper**

- [ ] `RequireJWTOrCICD` becomes `RequireJWTOrMachine`: accepts a valid Keycloak user JWT **or** a valid GitHub OIDC token **or** (transitionally) the old `CICD_WEBHOOK_SECRET`
- [ ] Map a validated OIDC token to the machine auth context (`IsMachine=true`), scoped to the claimed repo's project — this is stronger than the old secret, which granted tracker-wide write

**7.3 — Workflows: request and send the token**

- [ ] Update the reusable workflows (Phase 8) to request an OIDC token (`permissions: id-token: write`) and send it in the `Authorization` header instead of the CI secret
- [ ] Run one repo on OIDC end to end before touching the rest

**7.4 — Retire the secret**

- [ ] Dual-accept period: backend takes OIDC or the old secret, so already-enrolled repos keep working during migration
- [ ] Once all active repos send OIDC, remove `CICD_WEBHOOK_SECRET` from the accept list and stop provisioning it — this also removes the `--set-secrets` step's reason to exist entirely

**Checkpoint:** a CI run authenticates to DeployTrack with a short-lived OIDC token, scoped to its own repo's project, with no static secret anywhere in the repo. Attempting to write another project's resource with the wrong repo's token is rejected.

---

## Phase 8 — Central reusable-workflows repo

Goal: host the real CI/promote logic centrally so enrolled repos reference it by version instead of copying YAML that goes stale.

**8.1 — Create and populate the repo**

- [ ] Create `Blackbard22/deploytrack-workflows`
- [ ] Move the three current workflow templates into it as `workflow_call`-triggered files (dev CI, staging promote, production promote)
- [ ] Parameterize via `inputs` / `secrets: inherit` so a caller repo passes only what differs (project id, image repo — sourced from the repo variables the App set)
- [ ] Add `permissions: id-token: write` for the OIDC flow (Phase 7)

**8.2 — Version it**

- [ ] Tag a `v1` release; adopt a policy (callers pin `@v1`, you move the `v1` tag for backward-compatible changes, cut `@v2` for breaking ones)
- [ ] Document the upgrade path: bumping a caller from `@v1` to `@v2` is a one-line PR the App (or a bulk script) can open across repos

**8.3 — Wire the caller into enrollment**

- [ ] Implement `renderWorkflowCaller()` in `internal/jobs/enroll_repo.go` (the scaffold stub) to emit the 6-line `uses:` block pointing at the pinned tag
- [ ] Replace any placeholder workflow content from Phase 4 with this

**Checkpoint:** an enrolled repo's `.github/workflows/deploytrack.yml` is six lines referencing `deploytrack-workflows@v1`; changing the central logic and moving the tag changes behavior for all repos on next run, with no per-repo edit.

---



## Phase 9 — Resilience & observability hardening

Goal: operationalize the edge-cases doc so the system behaves under bursts, redelivery, and partial failure at 200-dev scale. Much of this is configuration of what's already scaffolded, plus visibility.

**9.1 — River tuning**

- [ ] Confirm per-job-type `MaxWorkers` concurrency caps sized to stay under GitHub's 5000 req/hr per-installation budget (edge cases doc 1.4) — start conservative, tune from observed usage
- [ ] Confirm unique-job keys are scoped `repo_id + event_type`, not `repo_id` alone (edge cases doc 1.5)
- [ ] Confirm retry policy per job type matches the doc's table (5 attempts for enroll/sync, 3 for reconcile), and that auth/permission errors classify separately for fast-discard (edge cases doc 1.8, section 2)

**9.2 — Reconcile job scheduling**

- [ ] Wire `ReconcileJob` to run periodically (River's periodic-job feature or an external cron enqueuing it)
- [ ] Implement its "fill missing, don't force exact-match" behavior (edge cases doc 1.12) — reconcile fills gaps, doesn't fight intentional manual edits

**9.3 — Observability floor**

- [ ] Deploy `riverui` (read-only) for queued/running/discarded job visibility
- [ ] Add a scheduled check counting `discarded` jobs and `app_enrollments` stuck `pending` past ~1 hour, surfaced somewhere you'll see it (edge cases doc section 3)
- [ ] Structured logging of each job's terminal state with repo + error context

**9.4 — Rate-limit + backoff correctness**

- [ ] Read `X-RateLimit-Remaining` and back off proactively before exhaustion, not just on 429 (edge cases doc 1.4)
- [ ] Return rate-limit errors with a River retry delay derived from `X-RateLimit-Reset`

**Checkpoint:** a simulated burst (bulk-enqueue many enrollment jobs) drains at a controlled rate without hitting rate limits, redelivered webhooks are no-ops, a deliberately-broken config lands in `discarded` and shows up in riverui, and a killed-mid-job worker's work is retried cleanly.

---



## Phase 10 — Deploy & end-to-end integration test

Goal: run both services together in the real deployment topology and prove the whole path.

**10.1 — Deploy**

- [ ] Add the App service to the existing Docker Compose stack alongside the backend and shared Postgres (per the container diagram)
- [ ] Run River's own migrations (`river migrate-up`) against the shared Postgres
- [ ] Swap the App's webhook URL from the smee.io channel to the real deployed endpoint
- [ ] Mount the App private key as a secret (not an env var), point `GITHUB_APP_PRIVATE_KEY_PATH` at it

**10.2 — Full happy-path test**

- [ ] Fresh repo → topic label → enrollment PR appears → merge → push to dev → CI runs via reusable workflow → OIDC exchange succeeds → DeployTrack shows the build → QA approves → staging promote dispatched → staging deploy reported → client approves → production promote → release closed
- [ ] This exercises every phase 5–9 together

**10.3 — Failure-path tests (from the edge-cases doc)**

- [ ] Repo with no `.deploytrack.yaml` → defaults used
- [ ] Repo missing a `staging` branch in its config → promote skips that env correctly (proves the Phase 5 pipeline-from-data refactor)
- [ ] Re-trigger a webhook (GitHub "Redeliver") → no duplicate PR
- [ ] Revoke the App's permission mid-flight → job fast-discards, installation flagged
- [ ] Bulk-enroll dry run across a handful of test repos → controlled rate, no duplicates

**Checkpoint:** one repo has gone from "topic added" to "production release tracked" with zero manual steps beyond adding the topic and clicking the two approvals, and the failure paths behave as designed.

---



## Phase 11 — Rollout & decommission

Goal: move from test account to the real org, migrate existing repos, and retire the CLI.

**11.1 — Install on the real org**

- [ ] Re-register (or transfer) the App under the org with production credentials — fresh private key and webhook secret for production, per the Phase 1 note
- [ ] Org-admin approves the permission scopes (contents, pull requests, actions, metadata)

**11.2 — Onboard existing repos**

- [ ] Write the one-page internal doc: "add topic `deploytrack`, merge the PR, done"
- [ ] Bulk-enroll: admin-triggered job walking `gh repo list --org`, enqueuing an enrollment job per matching repo (reuses `EnrollRepoJob`, rate-limited by the worker pool)
- [ ] Provide the `workflow_dispatch` "enroll me" fallback for repos the auto-detection misses

**11.3 — Migrate off the CLI**

- [ ] For repos previously onboarded by `gh-deploytrack`, replace their copied workflow YAML with the reusable-workflow caller (a bulk PR script, same mechanism as a `@v1→@v2` bump)
- [ ] Once a batch has run on the new flow without issues for a week or two, decommission the `gh-deploytrack` CLI extension

**11.4 — Drop deprecated schema columns**

- [ ] After the soak period from Phase 5, run the follow-up migration dropping the old `component` varchars, the two `*_promote_dispatched_at` columns, and the project version-pref columns — once nothing reads them

**Checkpoint:** all active repos run on the GitHub App + reusable workflows + OIDC; no repo holds a static CI secret; the CLI is retired; the schema carries no dead columns.

---



## Phase 12 — Webhook delivery recovery

Goal: make sure no GitHub event is permanently lost when the App can't accept it. GitHub does **not** retry failed webhook deliveries automatically, but it keeps a log of every App delivery for **3 days** and lets you redeliver from it via the API. This phase makes `ReconcileJob` use that log, and makes the receiver safe to hit with the same event more than once.

Background: the receiver acknowledges an event (2xx) only once it's safely stored as a River job. If the backend is down but Postgres is up, the job is stored and River retries it, so no recovery is needed. Recovery is needed when the event never got stored: Postgres down (receiver returns 500, `receiver.go:58`) or the App down or unreachable. In both cases GitHub records the delivery as failed.

Reference: [Handling failed webhook deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries), [REST API endpoints for GitHub App webhooks](https://docs.github.com/en/rest/apps/webhooks), [Redelivering webhooks](https://docs.github.com/en/webhooks/testing-and-troubleshooting-webhooks/redelivering-webhooks) (the 3-day window).

**12.1 — Redeliver failed deliveries from `ReconcileJob`**

- [ ] Run often, e.g. every 5–15 minutes, well inside the 3-day window
- [ ] Keep a cursor (the last delivery ID you've checked) in a small table
- [ ] Use the App JWT (`internal/githubauth/appauth.go`; installation tokens are not accepted) to page through `GET /app/hook/deliveries` from that cursor
- [ ] Pick out the deliveries that failed, grouped by the delivery ID GitHub sends in the `X-GitHub-Delivery` header. A redelivery keeps the same ID, so skip any ID where a later attempt succeeded. Otherwise you'd redeliver something twice. Check this grouping against the actual API response before relying on it
- [ ] Call `POST /app/hook/deliveries/{delivery_id}/attempts` for each one that still needs it
- [ ] Fix the stale comment in `receiver.go` ("GitHub will redeliver on failure"); GitHub doesn't, this job does

**12.2 — Deduplicate in the receiver by delivery ID**

- [ ] Read the delivery ID in the receiver (`github.DeliveryID(r)`) and pass it into the job args
- [ ] Use it as River's uniqueness key (``DeliveryID string `river:"unique"` ``) for jobs where each event is distinct: `RenameRepoArgs`, `SyncInstallationArgs`, and future `workflow_run` / `deployment_status` jobs. A redelivery that arrives after all (or after a manual click in the GitHub UI) then becomes a no-op
- [ ] This also fixes a current bug: those jobs are unique on `repo_id` / `installation_id + action`, so a genuine second rename, or suspend → unsuspend → suspend, arriving while the first job is still retained is dropped as a duplicate
- [ ] Keep `EnrollRepoArgs` unique on `repo_id`. Collapsing every trigger into one "make this repo enrolled" job is the intended behavior there
- [ ] Confirm River's unique-state defaults and completed-job retention for the River version in use; the dedup window only lasts as long as completed jobs are retained (about 24h by default)

**12.3 — Make job effects safe to repeat and to reorder**

The delivery ID doesn't cover everything: redeliveries after the retention window, backfilled events (which have no delivery ID), and old events arriving after newer ones.

- [ ] Backend writes upsert on natural keys: `repo_id` for projects and enrollments (already in place), `run_id + run_attempt + component` for builds and deployments
- [ ] Treat the webhook as a signal and read the current state from GitHub: `RenameRepoJob` fetches the repo's current name by `repo_id` rather than trusting the payload; the installation job fetches the current suspended status

**12.4 — Backfill for outages longer than 3 days**

- [ ] For outages longer than 3 days, fall back to a workflow-runs backfill: list runs per enrolled repo since the cursor and upsert them through the same natural keys as 12.3. Workflow runs are kept far longer than webhook deliveries

**Checkpoint:** with the App stopped, trigger a repo rename and a CI run on a test repo, then restart the App. Within one reconcile interval both events are redelivered and processed, the delivery log shows the redelivered attempts as successful, and nothing is duplicated. Manually clicking "Redeliver" on an already-processed delivery changes nothing. Two genuine renames of the same repo in a row both land, and the tracker shows the final name.

**Dependency note:** this builds on Phase 9's `ReconcileJob` wiring and needs its body implemented (still a TODO in `reconcile.go`). Although numbered after rollout, land it before Phase 11 onboards the org: without it, every App or Postgres outage needs manual redelivery across many repos.

---



## Post-launch backlog (deferred, not blocking)

Deliberately out of the core project scope, worth tracking for later:

- **GitHub-team / IdP sync for** `project_members` — populate `source = github_team` by syncing membership from GitHub teams or an IdP group, replacing manual member rows. The schema already has the `source` column for this; the sync job is the only new work.
- **Self-hosted CI runners** — revisit `runs-on: ubuntu-latest` → `self-hosted` in the workflows repo if per-minute billing at 200-dev volume becomes expensive. Independent of everything above; a one-line change in the central workflows.
- **Splitting the App into receiver + worker processes** — only if you need to scale them independently. The queue already makes this a deployment change, not a code rewrite; the container diagram's single App box becomes two.
- **Config schema versioning beyond v1** — when `.deploytrack.yaml` evolves, add explicit `version` handling in `ResolveConfig` (edge cases doc 1.11) so old-shape repos keep parsing.

