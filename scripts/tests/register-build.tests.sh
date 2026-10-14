#!/usr/bin/env bash
# Tests for register-build/register-build.sh (the register-build action).
# DeployTrack and the registry are fakes (scripts/tests/fakes/{curl,docker}):
# each case writes canned responses, runs the script, then checks the
# requests it made, the docker calls, its outputs and its exit code.
# Needs bash and jq. Usage: scripts/tests/register-build.tests.sh

set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="$TESTS/../../register-build/register-build.sh"
FAKES="$TESTS/fakes"
chmod +x "$FAKES/curl" "$FAKES/docker" 2>/dev/null || true
failures=0
cases=0

D1="sha256:$(printf 'a%.0s' {1..64})"
D2="sha256:$(printf 'b%.0s' {1..64})"
SHA=0123456789abcdef0123456789abcdef01234567
CICD=cicd-secret-XYZ
CB_TOKEN=cb-token-Q1w2E3r4
IMAGE_TAG=ghcr.io/org/app:1.4.0-build2

# ---------------------------------------------------------------------------
# helpers (run inside a case's subshell)

bad=0
fail() {
  echo "  - $*"
  bad=1
}

# respond METHOD PATH STATUS [BODY] [N]: canned answer (for call N only).
respond() {
  local key="$1${2//\//_}"
  key="$FAKE_DIR/responses/$key${5:+.$5}"
  printf '%s' "$3" >"$key.status"
  printf '%s' "${4-}" >"$key.body"
}

pending_import() {
  jq -nc --arg d "$D1" --arg img "$IMAGE_TAG" --arg tok "$CB_TOKEN" --arg st "${1:-pending}" '{
    build: {id: 57, import_status: $st, import_attempt: 1, source_image: ("ghcr.io/org/app@" + $d),
            source_digest: $d, docker_image: $img},
    version: "1.4.0", build_number: 2, docker_image: $img, component: "backend",
    idempotent: false, retried: false, retag: "caller"}
    + (if $st == "pending" then {callback: {url: "/api/builds/57/import-result", attempt: 1, token: $tok}} else {} end)'
}

lookup_pending() {
  jq -nc --arg d "$D1" --arg img "$IMAGE_TAG" --arg tok "$CB_TOKEN" '{
    build_id: 57, status: "pending", attempt: 3, source_image: ("ghcr.io/org/app@" + $d),
    docker_image: $img, callback: {url: "/api/builds/57/import-result", attempt: 3, token: $tok}}'
}

run_action() {
  bash "$ACTION" >"$FAKE_DIR/out" 2>&1
  RC=$?
}

# Assertions; FILE paths are relative to FAKE_DIR.
want_rc() { [[ "$RC" == "$1" ]] || fail "exit $RC, want $1"; }
has() { grep -qF -- "$2" "$FAKE_DIR/$1" 2>/dev/null || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$FAKE_DIR/$1" 2>/dev/null || fail "$1 has: $2"; }
no_file() { [[ ! -e "$FAKE_DIR/$1" ]] || fail "$1 exists: $(head -c 300 "$FAKE_DIR/$1")"; }
eq() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }
json_eq() {
  local got want
  got="$(jq -S . "$FAKE_DIR/$1" 2>&1)"
  want="$(jq -S . <<<"$2")"
  [[ "$got" == "$want" ]] || fail "$1 body: got $(jq -c . <<<"$got" 2>/dev/null || echo "$got"), want $(jq -c . <<<"$want")"
}
calls() { cat "$FAKE_DIR/curl.count" 2>/dev/null || echo 0; }

# case_ NAME FUNCTION: run FUNCTION in a fresh fake environment.
case_() {
  local name="$1" fn="$2" dir log rc
  cases=$((cases + 1))
  dir="$(mktemp -d)"
  log="$(
    export FAKE_DIR="$dir"
    mkdir -p "$dir/responses" "$dir/runner-temp"
    export CURL="$FAKES/curl" DOCKER="$FAKES/docker" REGISTER_BUILD_RETRY_DELAY=0
    export TRACKER_URL=http://tracker.test/ TRACKER_TOKEN="$CICD"
    export COMPONENT=backend IMAGE="ghcr.io/org/app@$D1" COMMIT_SHA="$SHA" BRANCH=main
    export REPOSITORY=org/app REGISTRY_USERNAME=octocat REGISTRY_TOKEN=ghs_regtoken
    export RUNNER_TEMP="$dir/runner-temp" GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary"
    # The runner's own docker config: credentials that must not leak into the
    # action's, and a plugin dir that must.
    export DOCKER_CONFIG="$dir/user-docker"
    mkdir -p "$DOCKER_CONFIG"
    echo '{"auths":{"ghcr.io":{"auth":"c2VjcmV0"}},"credsStore":"desktop","cliPluginsExtraDirs":["/opt/plugins"]}' >"$DOCKER_CONFIG/config.json"
    unset PROJECT_ID BUILD_ID FAKE_DOCKER_DIGEST FAKE_DOCKER_FAIL_CREATE FAKE_DOCKER_CREATE_DIGEST
    "$fn"
    [[ "$bad" == 0 ]] || { echo "  script output:"; sed 's/^/     | /' "$dir/out" 2>/dev/null; exit 1; }
  )"
  rc=$?
  rm -rf "$dir"
  if [[ "$rc" == 0 ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name"
    echo "$log"
  fi
}

# ---------------------------------------------------------------------------
# register mode

t_digest_happy() {
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"build_id":57,"status":"built","attempt":1}'
  run_action
  want_rc 0
  eq "$(sed -n 1p "$FAKE_DIR/docker.log")" "login ghcr.io -u octocat --password-stdin" "first docker call"
  eq "$(cat "$FAKE_DIR/docker.password")" ghs_regtoken "registry password on stdin"
  eq "$(sed -n 2p "$FAKE_DIR/docker.log")" "buildx imagetools create -t $IMAGE_TAG ghcr.io/org/app@$D1" "retag argv"
  eq "$(sed -n 3p "$FAKE_DIR/docker.log")" "buildx imagetools inspect $IMAGE_TAG --format {{json .Manifest}}" "verify argv"
  eq "$(wc -l <"$FAKE_DIR/docker.log" | tr -d ' ')" 3 "docker calls"
  eq "$(calls)" 2 "tracker calls"
  eq "$(cat "$FAKE_DIR/curl.1.method") $(cat "$FAKE_DIR/curl.1.url")" "POST http://tracker.test/api/builds/import" "import request"
  json_eq curl.1.body "$(jq -nc --arg i "ghcr.io/org/app@$D1" --arg c "$SHA" \
    '{repository: "org/app", component: "backend", image: $i, commit_sha: $c, branch: "main", retag: "caller"}')"
  eq "$(cat "$FAKE_DIR/curl.2.method") $(cat "$FAKE_DIR/curl.2.url")" "POST http://tracker.test/api/builds/57/import-result" "callback request"
  json_eq curl.2.body "$(jq -nc --arg t "$CB_TOKEN" --arg d "$D1" '{attempt: 1, token: $t, status: "built", digest: $d}')"
  has curl.1.headers "Authorization: Bearer $CICD"
  has curl.2.headers "Authorization: Bearer $CICD"
  lacks curl.1.args "$CICD"
  lacks curl.2.args "$CICD"
  has output "build_id=57"
  has output "version=1.4.0"
  has output "docker_image=$IMAGE_TAG"
  has output "digest=$D1"
  has output "status=built"
  has summary "1.4.0 (build 2)"
  has summary "$IMAGE_TAG"
  has summary "$D1"
  local temp="$FAKE_DIR/runner-temp"
  if command -v cygpath >/dev/null 2>&1; then temp="$(cygpath -m "$temp")"; fi
  grep -qF "$temp/register-build." "$FAKE_DIR/docker.config" ||
    fail "DOCKER_CONFIG not isolated under RUNNER_TEMP: $(head -n 1 "$FAKE_DIR/docker.config")"
  # Only the plugin dirs carry over from the runner's config (buildx lives there).
  local user="$FAKE_DIR/user-docker"
  if command -v cygpath >/dev/null 2>&1; then user="$(cygpath -m "$user")"; fi
  json_eq docker.config.json "$(jq -nc --arg d "$user/cli-plugins" '{cliPluginsExtraDirs: ([$d, "/opt/plugins"] | unique)}')"
  [[ -z "$(ls -A "$FAKE_DIR/runner-temp")" ]] || fail "RUNNER_TEMP not cleaned: $(ls -A "$FAKE_DIR/runner-temp")"
}
case_ "digest input: import, retag, verify, callback, outputs" t_digest_happy

t_tag_input() {
  export IMAGE=ghcr.io/org/app:v2.0.1 FAKE_DOCKER_DIGEST="$D1"
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"status":"built"}'
  run_action
  want_rc 0
  eq "$(sed -n 1p "$FAKE_DIR/docker.log")" "login ghcr.io -u octocat --password-stdin" "login before inspect"
  eq "$(sed -n 2p "$FAKE_DIR/docker.log")" "buildx imagetools inspect ghcr.io/org/app:v2.0.1 --format {{json .Manifest}}" "resolve argv"
  eq "$(jq -r .image "$FAKE_DIR/curl.1.body")" "ghcr.io/org/app@$D1" "imported image"
  has docker.log "buildx imagetools create -t $IMAGE_TAG ghcr.io/org/app@$D1"
}
case_ "tag input resolves to its digest via imagetools inspect" t_tag_input

t_registry_port() {
  export IMAGE="localhost:5000/team/app:latest@$D1" PROJECT_ID=12 BRANCH=
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"status":"built"}'
  run_action
  want_rc 0
  json_eq curl.1.body "$(jq -nc --arg i "localhost:5000/team/app@$D1" --arg c "$SHA" \
    '{repository: "org/app", project_id: 12, component: "backend", image: $i, commit_sha: $c, retag: "caller"}')"
  eq "$(sed -n 1p "$FAKE_DIR/docker.log")" "login localhost:5000 -u octocat --password-stdin" "login host"
}
case_ "registry with a port, tag+digest input, project_id, no branch" t_registry_port

t_import_422() {
  respond POST /api/builds/import 422 '{"error":"component is managed by DeployTrack CI"}'
  run_action
  want_rc 1
  has out "::error::DeployTrack rejected the import (HTTP 422): component is managed by DeployTrack CI"
  no_file docker.log
  eq "$(calls)" 1 "tracker calls"
  no_file output
}
case_ "non-2xx import fails with the server's message" t_import_422

t_import_html() {
  respond POST /api/builds/import 502 '<html>Bad gateway</html>'
  run_action
  want_rc 1
  has out "DeployTrack rejected the import (HTTP 502): <html>Bad gateway</html>"
}
case_ "non-JSON error body is shown as is" t_import_html

t_unreachable() {
  respond POST /api/builds/import 000
  run_action
  want_rc 1
  has out "DeployTrack rejected the import (HTTP 000): could not reach DeployTrack at http://tracker.test"
}
case_ "unreachable tracker fails clearly" t_unreachable

t_missing_commit() {
  export COMMIT_SHA=
  run_action
  want_rc 1
  has out "::error::commit_sha is required"
  eq "$(calls)" 0 "tracker calls"
}
case_ "commit_sha is required" t_missing_commit

t_retag_fails() {
  export FAKE_DOCKER_FAIL_CREATE=1
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"status":"failed"}'
  run_action
  want_rc 1
  eq "$(jq -r '[.attempt, .token, .status] | join(" ")' "$FAKE_DIR/curl.2.body")" "1 $CB_TOKEN failed" "failed callback"
  has curl.2.body "imagetools create failed: ERROR: failed to push $IMAGE_TAG: denied: permission_denied"
  [[ "$(jq -r 'has("digest")' "$FAKE_DIR/curl.2.body")" == false ]] || fail "failed callback carries a digest"
  has out "::error::Could not retag ghcr.io/org/app@$D1 to $IMAGE_TAG"
  has out "permission_denied"
  has output "status=failed"
}
case_ "retag failure reports failed with stderr, then fails" t_retag_fails

t_digest_drift() {
  export FAKE_DOCKER_CREATE_DIGEST="$D2"
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"status":"failed"}'
  run_action
  want_rc 1
  eq "$(jq -r '.status + ": " + .error' "$FAKE_DIR/curl.2.body")" "failed: retag produced $D2, expected $D1" "failed callback"
}
case_ "retagged digest differs from the source: failed" t_digest_drift

t_idempotent_built() {
  respond POST /api/builds/import 200 "$(pending_import built | jq -c '.idempotent = true')"
  run_action
  want_rc 0
  no_file docker.log
  eq "$(calls)" 1 "tracker calls"
  has output "status=built"
  has output "build_id=57"
  has summary "already imported"
}
case_ "already built import: no docker calls, no callback" t_idempotent_built

t_callback_409_built() {
  respond POST /api/builds/import 200 "$(pending_import)"
  respond POST /api/builds/57/import-result 409 '{"status":"built","attempt":1}'
  run_action
  want_rc 0
  has output "status=built"
}
case_ "callback 409 for an already built build counts as success" t_callback_409_built

t_callback_409_failed() {
  respond POST /api/builds/import 200 "$(pending_import)"
  respond POST /api/builds/57/import-result 409 '{"status":"pending","attempt":2,"error":"attempt 1 is no longer current"}'
  run_action
  want_rc 1
  has out "::error::DeployTrack rejected the import result (HTTP 409): attempt 1 is no longer current"
  has output "status=failed"
}
case_ "callback 409 for a newer attempt fails" t_callback_409_failed

t_callback_retry() {
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 503 'unavailable' 1
  respond POST /api/builds/57/import-result 000 '' 2
  respond POST /api/builds/57/import-result 200 '{"status":"built"}'
  run_action
  want_rc 0
  eq "$(calls)" 4 "tracker calls"
  json_eq curl.4.body "$(cat "$FAKE_DIR/curl.2.body")"
}
case_ "callback retries 5xx and network errors with the same body" t_callback_retry

t_callback_marked_failed() {
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"import_status":"failed","error":"retag produced x, expected y"}'
  run_action
  want_rc 1
  has out "DeployTrack marked the import failed: retag produced x, expected y"
}
case_ "callback accepted but DeployTrack marks it failed" t_callback_marked_failed

t_token_masked() {
  respond POST /api/builds/import 201 "$(pending_import)"
  respond POST /api/builds/57/import-result 200 '{"status":"built"}'
  run_action
  want_rc 0
  eq "$(grep -cF "$CB_TOKEN" "$FAKE_DIR/out")" 1 "lines with the callback token"
  has out "::add-mask::$CB_TOKEN"
  lacks out "$CICD"
  lacks output "$CB_TOKEN"
  lacks summary "$CB_TOKEN"
}
case_ "callback token is masked and never printed otherwise" t_token_masked

# ---------------------------------------------------------------------------
# retag-only mode (promote.yml import job)

t_retag_only_404() {
  export BUILD_ID=57 COMPONENT= IMAGE= COMMIT_SHA=
  respond GET /api/builds/57/import 404 '{"error":"build 57 is not an import"}'
  run_action
  want_rc 0
  no_file docker.log
  eq "$(calls)" 1 "tracker calls"
  eq "$(cat "$FAKE_DIR/curl.1.method") $(cat "$FAKE_DIR/curl.1.url")" "GET http://tracker.test/api/builds/57/import" "lookup request"
  has out "nothing to import"
  has output "status=none"
}
case_ "retag-only: managed build (404) is a no-op" t_retag_only_404

t_retag_only_409() {
  export BUILD_ID=57
  respond GET /api/builds/57/import 409 '{"status":"built"}'
  run_action
  want_rc 0
  no_file docker.log
  has output "status=built"
}
case_ "retag-only: already built import (409) is a no-op" t_retag_only_409

t_retag_only_pending() {
  export BUILD_ID=57 COMPONENT= IMAGE= COMMIT_SHA=
  respond GET /api/builds/57/import 200 "$(lookup_pending)"
  respond POST /api/builds/57/import-result 200 '{"status":"built"}'
  run_action
  want_rc 0
  eq "$(sed -n 1p "$FAKE_DIR/docker.log")" "login ghcr.io -u octocat --password-stdin" "login"
  eq "$(sed -n 2p "$FAKE_DIR/docker.log")" "buildx imagetools create -t $IMAGE_TAG ghcr.io/org/app@$D1" "retag argv"
  json_eq curl.2.body "$(jq -nc --arg t "$CB_TOKEN" --arg d "$D1" '{attempt: 3, token: $t, status: "built", digest: $d}')"
  has output "version=1.4.0"
  has output "status=built"
  has out "::add-mask::$CB_TOKEN"
  has summary "1.4.0 (build 2)"
}
case_ "retag-only: pending import is retagged and reported" t_retag_only_pending

t_retag_only_error() {
  export BUILD_ID=57
  respond GET /api/builds/57/import 401 '{"error":"unauthorized"}'
  run_action
  want_rc 1
  has out "::error::DeployTrack refused the import lookup for build 57 (HTTP 401): unauthorized"
  no_file docker.log
}
case_ "retag-only: other errors fail" t_retag_only_error

echo
echo "$((cases - failures))/$cases passed"
[[ "$failures" -eq 0 ]]
