#!/usr/bin/env bash
# Report a dev CI failure that happened before a build was allocated (so
# there is no build to fail via POST /api/deployments) to DeployTrack:
#   POST {TRACKER_URL}/api/projects/{PROJECT_ID}/ci-failures
# DeployTrack turns it into a CI_FAILED notification.
#
# Executed: posts one report from the environment and always exits 0, so a
# report never hides or replaces the real failure. Any problem (no tracker
# URL, curl error, non-2xx) is a ::warning::. The token is never printed.
#   TRACKER_URL, TRACKER_TOKEN, PROJECT_ID   where to post (token optional)
#   STAGE       failed stage, ^[a-z_]{1,40}$ (default "detect")
#   MESSAGE     what went wrong (default "CI failed at <stage>")
#   RUN_URL, COMMIT_SHA, BRANCH, COMPONENT   optional context
#   CURL        curl binary (tests point it at a fake)
#
# Sourced: defines the helpers below without posting. The detect job's
# failure step uses failure_stage and failure_message to pick STAGE and
# MESSAGE for the report-failure job.

MAX_MESSAGE=2000

# failure_stage: the first failed detect stage, from the step outcomes in
# CHECKOUT_OUTCOME, CHECKOUT_SCRIPTS_OUTCOME, TOOLS_OUTCOME,
# TOOL_VERSIONS_OUTCOME, RESOLVE_OUTCOME, CHECK_OUTCOME and SELECT_OUTCOME
# (GitHub's steps.<id>.outcome). Prints "detect" when none failed.
failure_stage() {
  local pair
  for pair in \
    "checkout:${CHECKOUT_OUTCOME:-}" \
    "checkout:${CHECKOUT_SCRIPTS_OUTCOME:-}" \
    "tools:${TOOLS_OUTCOME:-}" \
    "tools:${TOOL_VERSIONS_OUTCOME:-}" \
    "resolve:${RESOLVE_OUTCOME:-}" \
    "check_components:${CHECK_OUTCOME:-}" \
    "select:${SELECT_OUTCOME:-}"; do
    if [[ "${pair#*:}" == failure ]]; then
      echo "${pair%%:*}"
      return
    fi
  done
  echo detect
}

# failure_message LOG: the first ::error:: line of LOG without its
# "::error ...::" prefix (plus "(and N more errors)" when there are more),
# else the last non-empty line. Prints nothing for a missing or empty log.
failure_message() {
  local log="$1" line count=0 first="" last=""
  [[ -f "$log" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" == "::error"*"::"* ]]; then
      count=$((count + 1))
      if [[ "$count" == 1 ]]; then
        line="${line#::error}"
        first="${line#*::}"
      fi
    elif [[ -n "${line//[[:space:]]/}" ]]; then
      last="$line"
    fi
  done <"$log"
  if [[ "$count" -gt 1 ]]; then
    echo "$first (and $((count - 1)) more errors)"
  elif [[ "$count" == 1 ]]; then
    echo "$first"
  else
    # A plain line can still carry another workflow command (::warning:: ...).
    if [[ "$last" == "::"*"::"* ]]; then
      last="${last#::}"
      last="${last#*::}"
    fi
    echo "$last"
  fi
}

# build_payload: the /ci-failures JSON body from STAGE, MESSAGE, RUN_URL,
# COMMIT_SHA, BRANCH and COMPONENT. Empty fields are left out, MESSAGE is
# cut to MAX_MESSAGE characters, and RUN_URL is kept only when it is https
# (DeployTrack rejects anything else).
build_payload() {
  local stage="${STAGE:-detect}" run_url="${RUN_URL:-}"
  [[ "$run_url" == https://* ]] || run_url=""
  jq -cn \
    --arg stage "$stage" \
    --arg message "${MESSAGE:-}" \
    --arg run_url "$run_url" \
    --arg commit_sha "${COMMIT_SHA:-}" \
    --arg branch "${BRANCH:-}" \
    --arg component "${COMPONENT:-}" \
    --argjson max "$MAX_MESSAGE" \
    '{
      stage: $stage,
      message: ((if $message == "" then "CI failed at \($stage)" else $message end) | .[0:$max]),
      run_url: $run_url,
      commit_sha: $commit_sha,
      branch: $branch,
      component: $component,
      workflow: "dev-ci"
    } | with_entries(select(.value != ""))'
}

# post: send build_payload to DeployTrack. Returns 0 on a 2xx, else warns
# and returns 1.
post() {
  local url="${TRACKER_URL%/}/api/projects/${PROJECT_ID}/ci-failures"
  local tmp payload code rc=0
  tmp="$(mktemp -d)" || return 1
  payload="$(build_payload)" || { rm -rf "$tmp"; echo "::warning::Could not build the CI failure report"; return 1; }
  printf '%s' "$payload" >"$tmp/body.json"
  # Headers go through a file so the token never appears on a command line.
  (
    umask 077
    printf 'Content-Type: application/json\n' >"$tmp/headers"
    if [[ -n "${TRACKER_TOKEN:-}" ]]; then
      printf 'Authorization: Bearer %s\n' "$TRACKER_TOKEN" >>"$tmp/headers"
    fi
  )
  code="$("${CURL:-curl}" -sS -o "$tmp/response" -w '%{http_code}' -X POST \
    -H "@$tmp/headers" --data-binary "@$tmp/body.json" "$url" 2>"$tmp/stderr")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    echo "::warning::Could not report the CI failure to DeployTrack (curl exit $rc): $(head -c 300 "$tmp/stderr" | tr -d '\r\n')"
    rm -rf "$tmp"
    return 1
  fi
  if [[ "$code" != 2?? ]]; then
    echo "::warning::DeployTrack rejected the CI failure report (HTTP $code): $(head -c 300 "$tmp/response" | tr -d '\r\n')"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  echo "Reported the CI failure to DeployTrack (stage ${STAGE:-detect})."
}

main() {
  if [[ -z "${TRACKER_URL:-}" ]]; then
    echo "::warning::TRACKER_URL is not set; the CI failure was not reported to DeployTrack."
    return 0
  fi
  if [[ -z "${PROJECT_ID:-}" ]]; then
    echo "::warning::PROJECT_ID is not set; the CI failure was not reported to DeployTrack."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "::warning::jq is not installed; the CI failure was not reported to DeployTrack."
    return 0
  fi
  post || true
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
