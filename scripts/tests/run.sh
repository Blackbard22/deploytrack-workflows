#!/usr/bin/env bash
# Tests for the dev CI detect scripts (resolve-config.sh, check-components.sh,
# select-changed.sh) and its failure report (report-ci-failure.sh).
# Most cases build a throwaway repo layout and run the scripts in it.
# Needs bash, jq and yq (mikefarah). Usage: scripts/tests/run.sh

set -uo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
cases=0

# run_case NAME EXPECT_EXIT EXPECT_NAMES EXPECT_HAS SETUP...
#   EXPECT_NAMES: component names joined with "," ("" for none)
#   EXPECT_HAS:   true|false|- (- when the run is expected to fail)
#   SETUP:        shell commands run inside the empty repo dir
run_case() {
  local name="$1" want_exit="$2" want_names="$3" want_has="$4"
  shift 4
  cases=$((cases + 1))
  local dir out components got_exit names has
  dir="$(mktemp -d)"
  (cd "$dir" && eval "$*")

  out="$(cd "$dir" && GITHUB_OUTPUT='' bash "$SCRIPTS/resolve-config.sh" 2>/dev/null)"
  components="$(sed -n 's/^components=//p' <<<"$out")"
  out="$(cd "$dir" && GITHUB_OUTPUT='' bash "$SCRIPTS/check-components.sh" "$components" 2>&1)"
  got_exit=$?
  names="$(jq -r 'map(.name) | join(",")' <<<"$components")"
  has="$(sed -n 's/^has_components=//p' <<<"$out")"
  rm -rf "$dir"

  local ok=1
  [[ "$got_exit" == "$want_exit" ]] || ok=0
  [[ "$names" == "$want_names" ]] || ok=0
  [[ "$want_has" == "-" || "$has" == "$want_has" ]] || ok=0
  if [[ "$ok" == 1 ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name: exit=$got_exit (want $want_exit) names='$names' (want '$want_names') has='$has' (want '$want_has')"
    sed 's/^/     | /' <<<"$out"
  fi
}

run_case "empty repo: no components, not an error" 0 "" false \
  ":"

run_case "README only: no components" 0 "" false \
  "echo hi > README.md"

run_case "root Dockerfile: app" 0 "app" true \
  "echo 'FROM scratch' > Dockerfile"

run_case "compose with two buildable services" 0 "api,web" true \
  "mkdir api web && echo 'FROM scratch' > api/Dockerfile && echo 'FROM scratch' > web/Dockerfile.prod" \
  "&& printf 'services:\n  api:\n    build: ./api\n  web:\n    build:\n      context: ./web\n      dockerfile: Dockerfile.prod\n  db:\n    image: postgres:16\n' > docker-compose.yml"

run_case "compose service missing its Dockerfile fails the run" 1 "api,web" - \
  "mkdir api web && echo 'FROM scratch' > api/Dockerfile" \
  "&& printf 'services:\n  api:\n    build: ./api\n  web:\n    build: ./web\n' > compose.yaml"

run_case "compose service with missing build context fails" 1 "api" - \
  "printf 'services:\n  api:\n    build: ./api\n' > docker-compose.yml"

run_case "compose without build services and no Dockerfile: none" 0 "" false \
  "printf 'services:\n  db:\n    image: postgres:16\n' > docker-compose.yml"

run_case "compose without build services, root Dockerfile: app" 0 "app" true \
  "echo 'FROM scratch' > Dockerfile && printf 'services:\n  db:\n    image: postgres:16\n' > docker-compose.yml"

run_case ".deploytrack.yaml component missing its Dockerfile fails" 1 "api" - \
  "mkdir api && printf 'version: 1\ncomponents:\n  - name: api\n    path: ./api\n' > .deploytrack.yaml"

run_case ".deploytrack.yaml explicit component present" 0 "api" true \
  "mkdir api && echo 'FROM scratch' > api/Dockerfile && printf 'version: 1\ncomponents:\n  - name: api\n    path: ./api\n' > .deploytrack.yaml"

run_case ".deploytrack.yaml without components, no Dockerfile: none" 0 "" false \
  "printf 'version: 1\nbranches: [dev, production]\n' > .deploytrack.yaml"

# ---------------------------------------------------------------------------
# check-components.sh: components DeployTrack marks as external

# ext_case NAME EXPECT_EXIT EXPECT_NAMES EXPECT_EXTERNAL BASELINES SETUP...
#   EXPECT_NAMES:    buildable component names left, joined with ","
#   EXPECT_EXTERNAL: the `external` output, as compact JSON ("-" when failing)
ext_case() {
  local name="$1" want_exit="$2" want_names="$3" want_ext="$4" baselines="$5"
  shift 5
  cases=$((cases + 1))
  local dir out components got_exit names ext
  dir="$(mktemp -d)"
  (cd "$dir" && eval "$*")
  out="$(cd "$dir" && GITHUB_OUTPUT='' bash "$SCRIPTS/resolve-config.sh" 2>/dev/null)"
  components="$(sed -n 's/^components=//p' <<<"$out")"
  out="$(cd "$dir" && GITHUB_OUTPUT='' BASELINES="$baselines" bash "$SCRIPTS/check-components.sh" "$components" 2>&1)"
  got_exit=$?
  names="$(sed -n 's/^components=//p' <<<"$out" | jq -r 'map(.name) | join(",")' 2>/dev/null)"
  ext="$(sed -n 's/^external=//p' <<<"$out")"
  rm -rf "$dir"
  if [[ "$got_exit" == "$want_exit" && ( "$want_exit" != 0 || ( "$names" == "$want_names" && "$ext" == "$want_ext" ) ) ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name: exit=$got_exit (want $want_exit) names='$names' (want '$want_names') external='$ext' (want '$want_ext')"
    sed 's/^/     | /' <<<"$out"
  fi
}

API_WEB_COMPOSE="mkdir api web && echo 'FROM scratch' > web/Dockerfile && printf 'services:
  api:
    build: ./api
  web:
    build: ./web
' > compose.yaml"
API_EXTERNAL='{"components":{"api":{"commit_sha":"","version_requested":false,"build_mode":"external"},"web":{"build_id":3,"commit_sha":"abc","version_requested":false,"build_mode":"managed"}}}'

ext_case "external component without a Dockerfile is skipped, not an error" 0 "web" '["api"]' "$API_EXTERNAL"   "$API_WEB_COMPOSE"

ext_case "only external components: nothing to build" 0 "" '["api"]'   '{"components":{"api":{"build_mode":"external"}}}'   "mkdir api && printf 'version: 1
components:
  - name: api
    path: ./api
' > .deploytrack.yaml"

ext_case "external name matches case-insensitively" 0 "web" '["api"]'   '{"components":{"API":{"build_mode":"external"}}}'   "$API_WEB_COMPOSE"

ext_case "no build_mode field means managed: missing Dockerfile still fails" 1 - -   '{"components":{"api":{"commit_sha":"","version_requested":false}}}'   "$API_WEB_COMPOSE"

ext_case "empty BASELINES: old behaviour, missing Dockerfile fails" 1 - - ""   "$API_WEB_COMPOSE"

ext_case "invalid BASELINES: nothing is external" 0 "web" '[]' "not json"   "mkdir web && echo 'FROM scratch' > web/Dockerfile && printf 'services:
  web:
    build: ./web
' > compose.yaml"

ext_case "managed components are kept" 0 "api,web" '[]'   '{"components":{"api":{"build_mode":"managed"},"web":{"build_mode":"managed"}}}'   "mkdir api web && echo 'FROM scratch' > api/Dockerfile && echo 'FROM scratch' > web/Dockerfile && printf 'services:
  api:
    build: ./api
  web:
    build: ./web
' > compose.yaml"

# ---------------------------------------------------------------------------
# resolve-config.sh: the build: block (shared_changes, ignore)

# cfg_case NAME EXPECT_EXIT EXPECT_SHARED EXPECT_IGNORE SETUP...
cfg_case() {
  local name="$1" want_exit="$2" want_shared="$3" want_ignore="$4"
  shift 4
  cases=$((cases + 1))
  local dir out got_exit shared ignore
  dir="$(mktemp -d)"
  (cd "$dir" && eval "$*")
  out="$(cd "$dir" && GITHUB_OUTPUT='' bash "$SCRIPTS/resolve-config.sh" 2>&1)"
  got_exit=$?
  shared="$(sed -n 's/^shared_changes=//p' <<<"$out")"
  ignore="$(sed -n 's/^ignore=//p' <<<"$out")"
  rm -rf "$dir"
  if [[ "$got_exit" == "$want_exit" && ( "$want_exit" != 0 || ( "$shared" == "$want_shared" && "$ignore" == "$want_ignore" ) ) ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name: exit=$got_exit (want $want_exit) shared='$shared' (want '$want_shared') ignore='$ignore' (want '$want_ignore')"
    sed 's/^/     | /' <<<"$out"
  fi
}

cfg_case "no config: rebuild all on shared changes, default ignore" 0 all '["*.md","docs/",".github/"]' \
  ":"

cfg_case "build block overrides both" 0 none '["*.md","scripts/"]' \
  "printf 'version: 1\nbuild:\n  shared_changes: none\n  ignore: [\"*.md\", \"scripts/\"]\n' > .deploytrack.yaml"

cfg_case "invalid shared_changes fails" 1 - - \
  "printf 'version: 1\nbuild:\n  shared_changes: sometimes\n' > .deploytrack.yaml"

# ---------------------------------------------------------------------------
# select-changed.sh: which components build on this run

commit() { git add -A && git commit -qm "$1"; }

# A repo with api/ and web/ components plus shared and doc files, committed;
# BASE is that commit. Callers then change files and commit again.
two_components() {
  git init -q && git config user.email t@example.com && git config user.name t
  mkdir -p api web docs
  echo a >api/main && echo w >web/index && echo s >shared.txt && echo d >docs/guide.txt
  commit init
  BASE="$(git rev-parse HEAD)"
  export COMPONENTS='[{"name":"api","path":"api"},{"name":"web","path":"./web/"}]'
  export IGNORE='["*.md","docs/",".github/"]'
}

# baselines_for NAME... : DeployTrack baselines for NAMEs, all at $BASE.
baselines_for() {
  local json='{"components":{}}' n
  for n in "$@"; do
    json="$(jq -c --arg n "$n" --arg s "$BASE" '.components[$n] = {commit_sha: $s, version_requested: false}' <<<"$json")"
  done
  export BASELINES="$json"
}

# sel_case NAME EXPECT_BUILD EXPECT_SKIPPED SETUP...  (names joined with ",")
sel_case() {
  local name="$1" want_build="$2" want_skip="$3"
  shift 3
  cases=$((cases + 1))
  local dir out build skip
  dir="$(mktemp -d)"
  out="$(cd "$dir" && unset BASELINES FORCE SHARED_CHANGES EXTERNAL && eval "$*" >/dev/null &&
    GITHUB_OUTPUT='' GITHUB_STEP_SUMMARY='' bash "$SCRIPTS/select-changed.sh" 2>&1)"
  build="$(sed -n 's/^components=//p' <<<"$out" | jq -r 'map(.name) | join(",")' 2>/dev/null)"
  skip="$(sed -n 's/^skipped=//p' <<<"$out" | jq -r 'map(.name) | join(",")' 2>/dev/null)"
  rm -rf "$dir"
  if [[ "$build" == "$want_build" && "$skip" == "$want_skip" ]]; then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    echo "FAIL $name: build='$build' (want '$want_build') skipped='$skip' (want '$want_skip')"
    sed 's/^/     | /' <<<"$out"
  fi
}

sel_case "web-only change builds web" web api \
  "two_components && baselines_for api web && echo x >>web/index && commit c"

sel_case "shared file change rebuilds all by default" api,web "" \
  "two_components && baselines_for api web && echo x >>shared.txt && commit c"

sel_case "shared file change with shared_changes=none builds none" "" api,web \
  "two_components && baselines_for api web && export SHARED_CHANGES=none && echo x >>shared.txt && commit c"

sel_case "README change is ignored" "" api,web \
  "two_components && baselines_for api web && echo x >README.md && commit c"

sel_case "markdown inside a component is ignored" "" api,web \
  "two_components && baselines_for api web && echo x >web/NOTES.md && commit c"

sel_case "docs/ change is ignored" "" api,web \
  "two_components && baselines_for api web && echo x >>docs/guide.txt && commit c"

sel_case "nothing changed builds nothing" "" api,web \
  "two_components && baselines_for api web"

sel_case "component without a baseline builds" web api \
  "two_components && baselines_for api"

sel_case "baseline commit missing from history builds" api web \
  "two_components && baselines_for web && export BASELINES=\$(jq -c '.components.api = {commit_sha: \"0123456789abcdef0123456789abcdef01234567\"}' <<<\"\$BASELINES\")"

sel_case "no baseline data builds everything" api,web "" \
  "two_components && export BASELINES="

sel_case "force list builds the named component" web api \
  "two_components && baselines_for api web && export FORCE=' WEB '"

sel_case "force all builds everything" api,web "" \
  "two_components && baselines_for api web && export FORCE=all"

sel_case "requested version builds the component" api web \
  "two_components && baselines_for api web && export BASELINES=\$(jq -c '.components.api.version_requested = true' <<<\"\$BASELINES\")"

sel_case "file moved out of a component counts for it" api,web "" \
  "two_components && baselines_for api web && git mv api/main moved.txt && commit c"

sel_case "root component builds on any non-ignored change" app "" \
  "two_components && export COMPONENTS='[{\"name\":\"app\",\"path\":\".\"}]' && baselines_for app && echo x >>shared.txt && commit c"

sel_case "root component skips ignored-only changes" "" app \
  "two_components && export COMPONENTS='[{\"name\":\"app\",\"path\":\".\"}]' && baselines_for app && echo x >README.md && commit c"

# External components (EXTERNAL from check-components.sh, which already dropped
# them from COMPONENTS) are listed as skipped and never built, even when forced.
api_external() {
  two_components && baselines_for web
  export BASELINES=$(jq -c '.components.api = {commit_sha: "", version_requested: false, build_mode: "external"}' <<<"$BASELINES")
  export COMPONENTS='[{"name":"web","path":"./web/"}]' EXTERNAL='["api"]'
}

sel_case "mixed repo: external api skipped, changed web builds" web api   "api_external && echo x >>web/index && echo x >>api/main && commit c"

sel_case "force all keeps the external component skipped" web api   "api_external && export FORCE=all"

sel_case "forcing an external component by name keeps it skipped" "" web,api   "api_external && export FORCE=api"

sel_case "external component still in COMPONENTS is not built" web api   "api_external && export COMPONENTS='[{\"name\":\"api\",\"path\":\"api\"},{\"name\":\"web\",\"path\":\"./web/\"}]' FORCE=all"

sel_case "invalid EXTERNAL fails" "" ""   "api_external && export EXTERNAL=api"

# Reason and warning text for an external component.
cases=$((cases + 1))
dir="$(mktemp -d)"
summary="$dir/summary.md"
out="$(cd "$dir" && unset FORCE SHARED_CHANGES && api_external >/dev/null && export FORCE=api &&
  GITHUB_OUTPUT='' GITHUB_STEP_SUMMARY="$summary" bash "$SCRIPTS/select-changed.sh" 2>&1)"
reason="$(sed -n 's/^skipped=//p' <<<"$out" | jq -r '.[] | select(.name == "api") | .reason' 2>/dev/null)"
if [[ "$reason" == "external build (imported, not built here)" ]] &&
  grep -q "^::warning::Component 'api' builds externally" <<<"$out" &&
  grep -qF '| api | no | external build (imported, not built here) |' "$summary"; then
  echo "ok   external component: skip reason, summary row and force warning"
else
  failures=$((failures + 1))
  echo "FAIL external component: skip reason, summary row and force warning (reason='$reason')"
  sed 's/^/     | /' <<<"$out"
  [[ -f "$summary" ]] && sed 's/^/     S /' "$summary"
fi
rm -rf "$dir"

# ---------------------------------------------------------------------------
# report-ci-failure.sh: dev CI failures before a build is allocated

# check NAME CONDITION [DETAIL]: one assertion, CONDITION evaluated by eval.
check() {
  cases=$((cases + 1))
  if eval "$2"; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    echo "FAIL $1"
    [[ -n "${3:-}" ]] && sed 's/^/     | /' <<<"$3"
  fi
}

# Helpers without posting: sourcing must not run main.
helpers="$(source "$SCRIPTS/report-ci-failure.sh" && declare -F | awk '{print $3}' | tr '\n' ' ')"
check "sourcing defines the helpers and posts nothing" \
  '[[ " $helpers " == *" failure_stage "* && " $helpers " == *" failure_message "* && " $helpers " == *" build_payload "* ]]' "$helpers"

stage() { (source "$SCRIPTS/report-ci-failure.sh" && failure_stage); }
check "stage: first failed step wins" \
  '[[ "$(RESOLVE_OUTCOME=success CHECK_OUTCOME=failure SELECT_OUTCOME=failure stage)" == check_components ]]'
check "stage: scripts checkout counts as checkout" \
  '[[ "$(CHECKOUT_OUTCOME=success CHECKOUT_SCRIPTS_OUTCOME=failure TOOLS_OUTCOME=skipped stage)" == checkout ]]'
check "stage: tool versions counts as tools" \
  '[[ "$(TOOLS_OUTCOME=success TOOL_VERSIONS_OUTCOME=failure stage)" == tools ]]'
check "stage: select" \
  '[[ "$(RESOLVE_OUTCOME=success CHECK_OUTCOME=success SELECT_OUTCOME=failure stage)" == select ]]'
check "stage: nothing failed falls back to detect" \
  '[[ "$(RESOLVE_OUTCOME=success CHECK_OUTCOME=cancelled stage)" == detect ]]'

dir="$(mktemp -d)"
msg() { (source "$SCRIPTS/report-ci-failure.sh" && failure_message "$1"); }
printf '%s\n' "components=[]" "::notice::Component 'x' builds externally" \
  "::error::Component 'api': Dockerfile 'api/Dockerfile' not found" \
  "::error::Component 'web': build context 'web' not found" \
  "2 component(s) cannot be built." >"$dir/two-errors.log"
check "message: first ::error:: line, more errors counted" \
  '[[ "$(msg "$dir/two-errors.log")" == "Component '"'"'api'"'"': Dockerfile '"'"'api/Dockerfile'"'"' not found (and 1 more errors)" ]]' \
  "$(msg "$dir/two-errors.log")"
printf '%s\r\n' "noise" "::error file=C:\\repo\\.deploytrack.yaml,line=3::bad shared_changes" >"$dir/file-prefix.log"
check "message: ::error file=...:: prefix and CR stripped" \
  '[[ "$(msg "$dir/file-prefix.log")" == "bad shared_changes" ]]' "$(msg "$dir/file-prefix.log" | od -c | head -3)"
printf '%s\n' "resolving" "yq: Error: bad file '.deploytrack.yaml'" "   " "" >"$dir/no-error.log"
check "message: no ::error:: line uses the last non-empty line" \
  '[[ "$(msg "$dir/no-error.log")" == "yq: Error: bad file '"'"'.deploytrack.yaml'"'"'" ]]' "$(msg "$dir/no-error.log")"
printf '%s\n' "::warning::select failed: bad EXTERNAL" >"$dir/warning.log"
check "message: workflow command prefix stripped from the last line" \
  '[[ "$(msg "$dir/warning.log")" == "select failed: bad EXTERNAL" ]]' "$(msg "$dir/warning.log")"
check "message: missing log prints nothing" '[[ -z "$(msg "$dir/nope.log")" ]]'

payload() { (source "$SCRIPTS/report-ci-failure.sh" && build_payload); }
p="$(STAGE=check_components MESSAGE=$'Component "api": "quoted"\nsecond line' RUN_URL=https://github.com/acme/web/actions/runs/1/attempts/2 \
  COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 BRANCH=dev COMPONENT=api payload)"
check "payload: every field, JSON-escaped message" \
  '[[ "$(jq -r "[.stage, .message, .run_url, .commit_sha, .branch, .component, .workflow] | join(\"|\")" <<<"$p")" == "check_components|Component \"api\": \"quoted\"
second line|https://github.com/acme/web/actions/runs/1/attempts/2|0123456789abcdef0123456789abcdef01234567|dev|api|dev-ci" ]]' "$p"
p="$(STAGE=resolve payload)"
check "payload: default message, empty fields left out" \
  '[[ "$p" == "{\"stage\":\"resolve\",\"message\":\"CI failed at resolve\",\"workflow\":\"dev-ci\"}" ]]' "$p"
p="$(STAGE=select MESSAGE="$(printf 'é%.0s' $(seq 2500))" payload)"
check "payload: message cut to 2000 characters" '[[ "$(jq -r ".message | length" <<<"$p")" == 2000 ]]' "$(head -c 200 <<<"$p")"
p="$(STAGE=baselines RUN_URL=http://ghes.local/acme/web/actions/runs/1 payload)"
check "payload: non-https run_url left out" '[[ "$(jq -r "has(\"run_url\")" <<<"$p")" == false ]]' "$p"

# A fake curl that records the request in $FAKE_DIR and answers with
# $FAKE_STATUS / $FAKE_EXIT. Kept in the temp dir (not tests/fakes/).
cat >"$dir/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-X) shift 2 ;;
    -H) [[ "$2" == @* ]] && cat "${2#@}" >>"$FAKE_DIR/headers"; shift 2 ;;
    --data-binary) cat "${2#@}" >"$FAKE_DIR/body"; shift 2 ;;
    -*) shift ;;
    *) echo "$1" >"$FAKE_DIR/url"; shift ;;
  esac
done
[[ "${FAKE_EXIT:-0}" == 0 ]] || { echo "curl: (7) Failed to connect" >&2; exit "$FAKE_EXIT"; }
[[ -n "$out" ]] && printf '%s' '{"error":"stage is invalid"}' >"$out"
printf '%s' "${FAKE_STATUS:-201}"
EOF
chmod +x "$dir/curl"

# report [ENV=VALUE...]: run the script with the fake curl; sets out, rc.
report() {
  rm -rf "$dir/req" && mkdir "$dir/req"
  out="$(env -i PATH="$PATH" HOME="$HOME" CURL="$dir/curl" FAKE_DIR="$dir/req" \
    TRACKER_URL=https://tracker.example/ TRACKER_TOKEN=s3cr3t-token PROJECT_ID=7 \
    STAGE=check_components MESSAGE="Dockerfile 'api/Dockerfile' not found" "$@" \
    bash "$SCRIPTS/report-ci-failure.sh" 2>&1)"
  rc=$?
}

report
check "post: URL, Authorization header and body sent; token not printed" \
  '[[ $rc == 0 && "$(cat "$dir/req/url")" == https://tracker.example/api/projects/7/ci-failures ]] &&
   grep -qx "Authorization: Bearer s3cr3t-token" "$dir/req/headers" &&
   grep -qx "Content-Type: application/json" "$dir/req/headers" &&
   [[ "$(jq -r .stage "$dir/req/body")" == check_components ]] &&
   [[ "$out" == *"Reported the CI failure"* && "$out" != *s3cr3t* ]]' "$out"
report FAKE_STATUS=422
check "post: non-2xx is a warning and exit 0" \
  '[[ $rc == 0 && "$out" == "::warning::DeployTrack rejected the CI failure report (HTTP 422)"* && "$out" != *s3cr3t* ]]' "$out"
report FAKE_EXIT=7
check "post: curl error is a warning and exit 0" \
  '[[ $rc == 0 && "$out" == "::warning::Could not report the CI failure to DeployTrack (curl exit 7)"* ]]' "$out"
report TRACKER_URL=
check "post: no tracker URL skips the report" \
  '[[ $rc == 0 && "$out" == "::warning::TRACKER_URL is not set"* && ! -f "$dir/req/url" ]]' "$out"
report TRACKER_TOKEN=
check "post: no token sends no Authorization header" \
  '[[ $rc == 0 ]] && ! grep -q Authorization "$dir/req/headers"' "$out"
rm -rf "$dir"

echo
echo "$((cases - failures))/$cases passed"
[[ "$failures" -eq 0 ]]
