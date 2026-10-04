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

echo
echo "$((cases - failures))/$cases passed"
[[ "$failures" -eq 0 ]]
