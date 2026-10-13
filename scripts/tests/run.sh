#!/usr/bin/env bash
# Tests for resolve-config.sh + check-components.sh, the dev CI detect step.
# Each case builds a throwaway repo layout and runs both scripts in it.
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

echo
echo "$((cases - failures))/$cases passed"
[[ "$failures" -eq 0 ]]
