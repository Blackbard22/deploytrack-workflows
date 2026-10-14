#!/usr/bin/env bash
# Register an externally built image with DeployTrack and retag it to the
# version DeployTrack allocates. Logic of the register-build action
# (register-build/action.yml); see register-build/README.md.
#
# Register mode (BUILD_ID empty):
#   1. resolve IMAGE to <repo>@<digest> (a tag is inspected in the registry);
#   2. POST /api/builds/import with retag "caller";
#   3. already built => done; else retag in the registry with
#      `docker buildx imagetools create` (no pull, keeps manifest lists);
#   4. report the result to the build's import-result callback.
# Retag-only mode (BUILD_ID set, used by promote.yml's import job):
#   GET /api/builds/{id}/import; 404/409 => nothing to import (success);
#   else steps 3-4 for that pending import.
#
# Env: TRACKER_URL, TRACKER_TOKEN (required); COMPONENT, IMAGE, COMMIT_SHA
# (required in register mode); BRANCH, REPOSITORY, PROJECT_ID, BUILD_ID,
# REGISTRY_USERNAME, REGISTRY_TOKEN (optional). CURL and DOCKER override the
# binaries (tests inject fakes). Writes build_id, version, docker_image,
# digest and status to GITHUB_OUTPUT and a summary to GITHUB_STEP_SUMMARY
# when set; always prints the outputs.

set -euo pipefail

CURL="${CURL:-curl}"
DOCKER="${DOCKER:-docker}"
RETRY_DELAY="${REGISTER_BUILD_RETRY_DELAY:-3}"

die() {
  echo "::error::$*"
  exit 1
}

for v in TRACKER_URL TRACKER_TOKEN; do
  [[ -n "${!v:-}" ]] || die "$v is required"
done
command -v jq >/dev/null 2>&1 || die "jq is required"
TRACKER_URL="${TRACKER_URL%/}"

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/register-build.XXXXXX")"
# Git Bash: native curl/docker need a Windows path, which bash accepts too.
if command -v cygpath >/dev/null 2>&1; then work="$(cygpath -m "$work")"; fi
# Holds the bearer header and the registry login; never left behind.
trap 'rm -rf "$work"' EXIT
printf 'Authorization: Bearer %s\n' "$TRACKER_TOKEN" >"$work/auth.header"
chmod 600 "$work/auth.header"

# api METHOD PATH [JSON]: sets HTTP_STATUS ("000" when unreachable) and
# HTTP_BODY. The token goes in a header file, never on the command line.
api() {
  local method="$1" path="$2" body="${3-}"
  local args=(-sS -X "$method" -o "$work/resp" -w '%{http_code}'
    -H "@$work/auth.header" -H 'Accept: application/json')
  : >"$work/resp"
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @-)
  fi
  HTTP_STATUS="$(printf '%s' "$body" | "$CURL" "${args[@]}" "$TRACKER_URL$path")" || HTTP_STATUS=000
  [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]] || HTTP_STATUS=000
  HTTP_BODY="$(cat "$work/resp")"
}

# server_message: the response's .error, else the raw body (shortened).
server_message() {
  local msg
  msg="$(jq -r '(.error // .message // empty) | tostring' <<<"$HTTP_BODY" 2>/dev/null || true)"
  if [[ -z "$msg" ]]; then
    msg="${HTTP_BODY:0:500}"
  fi
  if [[ -z "$msg" && "$HTTP_STATUS" == 000 ]]; then
    msg="could not reach DeployTrack at $TRACKER_URL"
  fi
  printf '%s' "${msg:-no response body}"
}

field() { jq -r "$1 // empty" <<<"$HTTP_BODY" 2>/dev/null || true; }

# Registry host of an image reference: the first path segment when it looks
# like a host (has "." or ":" or is localhost), else Docker Hub.
registry_host() {
  local first="${1%%/*}"
  if [[ "$1" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    printf '%s' "$first"
  else
    printf 'docker.io'
  fi
}

# Log in once, lazily: an idempotent or no-op run never touches the registry.
logged_in=""
registry_login() {
  [[ -z "$logged_in" ]] || return 0
  logged_in=1
  # A fresh config also loses the CLI plugins (buildx) that live beside the
  # usual one (Docker Desktop: ~/.docker/cli-plugins), so point back at them.
  local orig="${DOCKER_CONFIG:-${USERPROFILE:-$HOME}/.docker}"
  if command -v cygpath >/dev/null 2>&1; then orig="$(cygpath -m "$orig")"; fi
  export DOCKER_CONFIG="$work/docker"
  mkdir -p "$DOCKER_CONFIG"
  { jq -c '.' "$orig/config.json" 2>/dev/null || echo '{}'; } |
    jq -c --arg d "$orig/cli-plugins" '{cliPluginsExtraDirs: ([(.cliPluginsExtraDirs // [])[], $d] | unique)}' \
      >"$DOCKER_CONFIG/config.json"
  if [[ -z "${REGISTRY_TOKEN:-}" ]]; then
    echo "::notice::No registry_token given; using the registry anonymously."
    return 0
  fi
  local host
  host="$(registry_host "$1")"
  printf '%s' "$REGISTRY_TOKEN" |
    "$DOCKER" login "$host" -u "${REGISTRY_USERNAME:-deploytrack}" --password-stdin >/dev/null ||
    die "docker login $host failed; the workflow token needs packages: write (or pass registry_token)"
}

# digest_of REF: the manifest (or index) digest the registry serves for REF.
digest_of() {
  "$DOCKER" buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r '.digest // empty'
}

# repo_of REF: REF without its @digest and :tag.
repo_of() {
  local ref="${1%%@*}" last
  last="${ref##*/}"
  if [[ "$last" == *:* ]]; then
    ref="${ref%:*}"
  fi
  printf '%s' "$ref"
}

build_id="" version="" build_number="" docker_image="" digest="" status=""
callback_path="" callback_attempt="" callback_token=""

write_outputs() {
  local line
  for line in "build_id=$build_id" "version=$version" "docker_image=$docker_image" \
    "digest=$digest" "status=$status"; do
    echo "$line"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$line" >>"$GITHUB_OUTPUT"; fi
  done
}

summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "### DeployTrack (register build${COMPONENT:+ — $COMPONENT})"
    echo "- **Result:** $1"
    if [[ -n "$version" ]]; then echo "- **Version:** $version${build_number:+ (build $build_number)}"; fi
    if [[ -n "$docker_image" ]]; then echo "- **Image:** \`$docker_image\`"; fi
    if [[ -n "$digest" ]]; then echo "- **Digest:** \`$digest\`"; fi
    if [[ -n "$build_id" ]]; then echo "- **build_id:** $build_id"; fi
  } >>"$GITHUB_STEP_SUMMARY"
}

# take_callback: read the callback from HTTP_BODY and mask its token.
take_callback() {
  callback_token="$(field '.callback.token')"
  callback_attempt="$(field '.callback.attempt')"
  callback_path="$(field '.callback.url')"
  [[ -n "$callback_token" && "$callback_attempt" =~ ^[0-9]+$ ]] ||
    die "DeployTrack returned no import callback for build $build_id"
  echo "::add-mask::$callback_token"
  # Only follow a path on this tracker; the bearer token goes with it.
  if [[ "$callback_path" != /api/* ]]; then
    callback_path="/api/builds/$build_id/import-result"
  fi
}

# report STATUS [ERROR]: POST the import result, retrying while DeployTrack
# is unreachable or failing (a replay of the same result is idempotent).
# Returns 0 when DeployTrack recorded the build as built.
report() {
  local result="$1" err="${2-}" body try
  body="$(jq -nc --argjson attempt "$callback_attempt" --arg token "$callback_token" \
    --arg status "$result" --arg digest "$digest" --arg error "$err" \
    '{attempt: $attempt, token: $token, status: $status}
     + (if $status == "built" then {digest: $digest} else {error: $error} end)')"
  for try in 1 2 3; do
    api POST "$callback_path" "$body"
    if [[ "$HTTP_STATUS" != 000 && "$HTTP_STATUS" != 5* ]]; then break; fi
    if [[ "$try" -lt 3 ]]; then
      echo "DeployTrack import-result call failed (HTTP $HTTP_STATUS); retrying" >&2
      sleep "$RETRY_DELAY"
    fi
  done
  local server_status
  server_status="$(field '.import_status // .status // .build.import_status')"
  if [[ "$HTTP_STATUS" == 2* ]]; then
    [[ "$result" == built && "$server_status" != failed ]] && return 0
    if [[ "$result" == built ]]; then
      echo "::error::DeployTrack marked the import failed: $(server_message)"
    fi
    return 1
  fi
  # A late or repeated callback for a build that is already built is fine.
  if [[ "$HTTP_STATUS" == 409 && "$server_status" == built ]]; then
    echo "DeployTrack already has build $build_id as built" >&2
    return 0
  fi
  echo "::error::DeployTrack rejected the import result (HTTP $HTTP_STATUS): $(server_message)"
  return 1
}

# retag SOURCE: copy SOURCE (repo@digest) to docker_image inside the
# registry, check the new tag serves the same digest, and report.
retag() {
  local source="$1" got
  registry_login "$source"
  echo "Retagging $source -> $docker_image" >&2
  if ! "$DOCKER" buildx imagetools create -t "$docker_image" "$source" 2>"$work/retag.err"; then
    cat "$work/retag.err" >&2
    local err
    err="$(tail -c 2000 "$work/retag.err")"
    report failed "imagetools create failed: ${err:-no output}" || true
    status=failed
    write_outputs
    summary "retag failed"
    die "Could not retag $source to $docker_image (see the log above)"
  fi
  got="$(digest_of "$docker_image" 2>"$work/retag.err" || true)"
  if [[ "$got" != "$digest" ]]; then
    local err="retag produced ${got:-no digest}, expected $digest"
    cat "$work/retag.err" >&2
    report failed "$err" || true
    status=failed
    write_outputs
    summary "retag failed"
    die "$err"
  fi
  if ! report built; then
    status=failed
    write_outputs
    summary "DeployTrack did not accept the result"
    exit 1
  fi
  status=built
}

if [[ -n "${BUILD_ID:-}" ]]; then
  # ---- retag-only mode ------------------------------------------------------
  [[ "$BUILD_ID" =~ ^[0-9]+$ ]] || die "build_id must be a number, got '$BUILD_ID'"
  build_id="$BUILD_ID"
  api GET "/api/builds/$build_id/import"
  case "$HTTP_STATUS" in
    2*) ;;
    404 | 409)
      status="$(field '.status')"
      status="${status:-none}"
      echo "Build $build_id has nothing to import (HTTP $HTTP_STATUS, status ${status}); nothing to do."
      write_outputs
      summary "nothing to import (build $build_id is ${status/none/not an import})"
      exit 0
      ;;
    *) die "DeployTrack refused the import lookup for build $build_id (HTTP $HTTP_STATUS): $(server_message)" ;;
  esac
  take_callback
  source_image="$(field '.source_image')"
  docker_image="$(field '.docker_image')"
  [[ "$source_image" == *@sha256:* ]] || die "build $build_id has no source digest (source_image '$source_image')"
  [[ -n "$docker_image" ]] || die "build $build_id has no docker_image"
  digest="${source_image#*@}"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "build $build_id has an invalid source digest '$digest'"
  tag="${docker_image##*:}"
  version="${tag%-build*}"
  if [[ "$tag" =~ -build([0-9]+)$ ]]; then build_number="${BASH_REMATCH[1]}"; fi
  retag "$source_image"
  write_outputs
  summary "imported"
  exit 0
fi

# ---- register mode ----------------------------------------------------------
for v in COMPONENT IMAGE COMMIT_SHA; do
  [[ -n "${!v:-}" ]] || die "$(tr '[:upper:]' '[:lower:]' <<<"$v") is required"
done
if [[ -n "${PROJECT_ID:-}" && ! "$PROJECT_ID" =~ ^[0-9]+$ ]]; then
  die "project_id must be a number, got '$PROJECT_ID'"
fi

repo="$(repo_of "$IMAGE")"
if [[ "$IMAGE" == *@sha256:* ]]; then
  digest="${IMAGE#*@}"
else
  registry_login "$IMAGE"
  digest="$(digest_of "$IMAGE")" || die "Could not read $IMAGE from the registry"
  [[ "$digest" == sha256:* ]] || die "Could not resolve the digest of $IMAGE"
  echo "Resolved $IMAGE to $digest" >&2
fi
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "image digest '$digest' is not sha256:<64 hex>"
canonical="$repo@$digest"

body="$(jq -nc --arg repository "${REPOSITORY:-}" --arg project_id "${PROJECT_ID:-}" \
  --arg component "$COMPONENT" --arg image "$canonical" --arg commit "$COMMIT_SHA" \
  --arg branch "${BRANCH:-}" '
  {component: $component, image: $image, commit_sha: $commit, retag: "caller"}
  + (if $repository != "" then {repository: $repository} else {} end)
  + (if $project_id != "" then {project_id: ($project_id | tonumber)} else {} end)
  + (if $branch != "" then {branch: $branch} else {} end)')"

echo "Importing $canonical as $COMPONENT (commit $COMMIT_SHA)" >&2
api POST /api/builds/import "$body"
if [[ "$HTTP_STATUS" != 2* ]]; then
  die "DeployTrack rejected the import (HTTP $HTTP_STATUS): $(server_message)"
fi

build_id="$(field '.build.id')"
version="$(field '.version')"
build_number="$(field '.build_number')"
docker_image="$(field '.docker_image // .build.docker_image')"
digest="$(field '.build.source_digest')"
digest="${digest:-${canonical#*@}}"
import_status="$(field '.build.import_status')"
[[ -n "$build_id" && -n "$docker_image" ]] || die "DeployTrack's import response has no build id or docker_image"
echo "DeployTrack build $build_id: $COMPONENT $version -> $docker_image" >&2

if [[ "$import_status" == built ]]; then
  status=built
  echo "$canonical is already imported as build $build_id; nothing to retag."
  write_outputs
  summary "already imported"
  exit 0
fi

take_callback
retag "$canonical"
write_outputs
summary "imported"
