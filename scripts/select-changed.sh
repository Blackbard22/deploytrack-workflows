#!/usr/bin/env bash
# Pick which resolved components dev CI should build on this run.
# Usage: select-changed.sh   (inputs come from the environment)
#
#   COMPONENTS      JSON array from check-components.sh
#   BASELINES       JSON from DeployTrack GET /api/projects/{id}/build-baselines:
#                   {"components": {"<name>": {"commit_sha": "...", "version_requested": bool}}}
#                   Empty when it could not be fetched: everything builds.
#   FORCE           "" (changed only), "all", or a comma list of component names
#   SHARED_CHANGES  "all" (default): a change outside every component folder
#                   rebuilds every component; "none": it builds nothing
#   IGNORE          JSON array of path patterns that never trigger a build.
#                   "*" matches any characters including "/"; a pattern ending
#                   in "/" matches everything under that folder.
#
# A component builds when it is forced, has no usable baseline (never built,
# or its commit is not in this checkout's history), has a new version
# requested, or `git diff <baseline> HEAD` (minus IGNORE) touches its folder,
# or touches a shared file while SHARED_CHANGES=all. Everything else is
# skipped with the reason. Needs a full-history checkout (fetch-depth: 0).
#
# Writes `components` (the ones to build), `has_components` and `skipped`
# (JSON [{name, reason}]) to GITHUB_OUTPUT when set, and a table to
# GITHUB_STEP_SUMMARY when set; always prints them.

set -euo pipefail

components="${COMPONENTS:-[]}"
baselines="${BASELINES:-}"
force="$(printf '%s' "${FORCE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
shared_changes="$(printf '%s' "${SHARED_CHANGES:-all}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
ignore="${IGNORE:-[]}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi
if ! jq -e 'type == "array"' <<<"$components" >/dev/null 2>&1; then
  echo "COMPONENTS is not a JSON array: $components" >&2
  exit 2
fi
case "$shared_changes" in
  all | none) ;;
  "") shared_changes=all ;;
  *)
    echo "build.shared_changes must be all or none (got '$shared_changes')" >&2
    exit 2
    ;;
esac
if ! jq -e 'type == "array"' <<<"$ignore" >/dev/null 2>&1; then
  echo "build.ignore must be a list of path patterns (got $ignore)" >&2
  exit 2
fi
if [[ -n "$baselines" ]] && ! jq -e '.components | type == "object"' <<<"$baselines" >/dev/null 2>&1; then
  echo "::warning::Build baselines are not valid JSON; building every component."
  baselines=""
fi

mapfile -t ignore_patterns < <(jq -r '.[]' <<<"$ignore")

# Folder prefix for a component path: "" for the repo root, else "dir/".
folder_of() {
  local p="${1:-.}"
  p="${p#./}"
  p="${p%/}"
  if [[ -z "$p" || "$p" == "." ]]; then
    printf ''
  else
    printf '%s/' "$p"
  fi
}

is_ignored() {
  local file="$1" pat
  for pat in "${ignore_patterns[@]}"; do
    [[ -z "$pat" ]] && continue
    if [[ "$pat" == */ ]]; then
      [[ "$file" == "$pat"* ]] && return 0
    else
      # shellcheck disable=SC2053 # unquoted on purpose: glob match
      [[ "$file" == $pat ]] && return 0
    fi
  done
  return 1
}

# Every component's folder; a root component claims the whole repo, so then
# nothing counts as shared.
folders=()
has_root=false
while IFS= read -r path; do
  f="$(folder_of "$path")"
  if [[ -z "$f" ]]; then
    has_root=true
  else
    folders+=("$f")
  fi
done < <(jq -r '.[] | (.path // ".")' <<<"$components")

is_shared() {
  local file="$1" f
  [[ "$has_root" == true ]] && return 1
  for f in "${folders[@]}"; do
    [[ "$file" == "$f"* ]] && return 1
  done
  return 0
}

forced() {
  local name="$1"
  [[ "$force" == "all" ]] && return 0
  [[ -z "$force" ]] && return 1
  [[ ",$force," == *",$name,"* ]]
}

selected='[]'
skipped='[]'
built='[]'
add() { # add <array-var> <component-json> <reason>
  local -n arr="$1"
  arr="$(jq -c --argjson c "$2" --arg r "$3" '. + [$c + {reason: $r}]' <<<"$arr")"
}

count="$(jq 'length' <<<"$components")"
for ((i = 0; i < count; i++)); do
  c="$(jq -c ".[$i]" <<<"$components")"
  name="$(jq -r '.name' <<<"$c" | tr '[:upper:]' '[:lower:]')"
  folder="$(folder_of "$(jq -r '.path // "."' <<<"$c")")"

  reason=""
  if forced "$name"; then
    reason="forced"
  elif [[ -z "$baselines" ]]; then
    reason="no baseline data"
  else
    base="$(jq -r --arg n "$name" '.components[$n].commit_sha // ""' <<<"$baselines")"
    requested="$(jq -r --arg n "$name" '.components[$n].version_requested // false' <<<"$baselines")"
    if [[ "$requested" == "true" ]]; then
      reason="new version requested"
    elif [[ -z "$base" ]]; then
      reason="no previous build"
    elif ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
      reason="previous build commit ${base:0:7} not in history"
    else
      own=false
      shared=false
      while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        is_ignored "$file" && continue
        if [[ -z "$folder" || "$file" == "$folder"* ]]; then
          own=true
          break
        fi
        if is_shared "$file"; then
          shared=true
        fi
      done < <(git diff --name-only --no-renames "$base" HEAD)

      if [[ "$own" == true ]]; then
        reason="changed since ${base:0:7}"
      elif [[ "$shared" == true && "$shared_changes" == "all" ]]; then
        reason="shared files changed since ${base:0:7}"
      else
        add skipped "$c" "unchanged since ${base:0:7}"
        continue
      fi
    fi
  fi
  selected="$(jq -c --argjson c "$c" '. + [$c]' <<<"$selected")"
  add built "$c" "$reason"
done

has_components=false
if [[ "$(jq 'length' <<<"$selected")" -gt 0 ]]; then
  has_components=true
fi
skipped_out="$(jq -c 'map({name, reason})' <<<"$skipped")"

echo "components=$selected"
echo "has_components=$has_components"
echo "skipped=$skipped_out"
jq -r '.[] | "build \(.name): \(.reason)"' <<<"$built"
jq -r '.[] | "skip  \(.name): \(.reason)"' <<<"$skipped"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "components<<EOF"
    echo "$selected"
    echo "EOF"
    echo "has_components=$has_components"
    echo "skipped<<EOF"
    echo "$skipped_out"
    echo "EOF"
  } >>"$GITHUB_OUTPUT"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### DeployTrack (dev CI): components"
    echo
    echo "| Component | Build | Why |"
    echo "|---|---|---|"
    jq -r '.[] | "| \(.name) | yes | \(.reason) |"' <<<"$built"
    jq -r '.[] | "| \(.name) | no | \(.reason) |"' <<<"$skipped"
    if [[ "$has_components" != true && "$count" -gt 0 ]]; then
      echo
      echo "Nothing changed, so nothing was built. Run the workflow manually with \`build: all\` (or a component name) to force a build."
    fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
