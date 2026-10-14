#!/usr/bin/env bash
# Verify that every resolved component can be built, before anything is
# allocated in DeployTrack.
# Usage: check-components.sh [components-json]   (default: $COMPONENTS)
#
# For each component, the build context (path) must be a directory and
# <path>/<dockerfile> must exist - the same join the build step uses. Any
# missing one is an error for the whole run: a component declared in
# .deploytrack.yaml or Compose without its Dockerfile is a broken config,
# so nothing is built until it is fixed.
#
# Components DeployTrack marks as external (build_mode "external" in
# BASELINES, the JSON from GET /api/projects/{id}/build-baselines) are built
# elsewhere and imported, so they are dropped before the check: they may have
# no Dockerfile at all. Empty or invalid BASELINES drops nothing.
#
# Writes `components` (buildable ones), `has_components` (true|false) and
# `external` (JSON array of the dropped names) to GITHUB_OUTPUT when set;
# always prints them. An empty list is not an error: the repo simply has
# nothing to build yet.

set -euo pipefail

components="${1:-${COMPONENTS:-}}"
if [[ -z "$components" ]]; then
  echo "usage: check-components.sh <components-json> (or set COMPONENTS)" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi
if ! jq -e 'type == "array"' <<<"$components" >/dev/null 2>&1; then
  echo "components is not a JSON array: $components" >&2
  exit 2
fi

external='[]'
if [[ -n "${BASELINES:-}" ]]; then
  external="$(jq -c '[(.components // {}) | to_entries[] | select(.value.build_mode == "external") | .key | ascii_downcase]' <<<"$BASELINES" 2>/dev/null)" || external='[]'
  [[ -n "$external" ]] || external='[]'
fi
while IFS= read -r name; do
  echo "::notice::Component '$name' builds externally; skipped (import its images instead)"
done < <(jq -r --argjson ext "$external" '.[] | select((.name | ascii_downcase) as $n | $ext | any(. == $n)) | .name' <<<"$components")
components="$(jq -c --argjson ext "$external" 'map(select((.name | ascii_downcase) as $n | $ext | any(. == $n) | not))' <<<"$components")"
count="$(jq 'length' <<<"$components")"

missing=0
while IFS=$'\t' read -r name path dockerfile; do
  path="${path:-.}"
  dockerfile="${dockerfile:-Dockerfile}"
  if [[ ! -d "$path" ]]; then
    echo "::error::Component '$name': build context '$path' not found"
    missing=$((missing + 1))
    continue
  fi
  file="${path%/}/$dockerfile"
  if [[ ! -f "$file" ]]; then
    echo "::error::Component '$name': Dockerfile '$file' not found"
    missing=$((missing + 1))
  fi
done < <(jq -r '.[] | [.name, (.path // "."), (.dockerfile // "Dockerfile")] | @tsv' <<<"$components")

if [[ "$missing" -gt 0 ]]; then
  echo "$missing component(s) cannot be built. Add the missing Dockerfile(s), or remove the component from .deploytrack.yaml / Compose. Nothing was built." >&2
  exit 1
fi

has_components=false
if [[ "$count" -gt 0 ]]; then
  has_components=true
fi

compact="$(jq -c '.' <<<"$components")"
echo "components=$compact"
echo "has_components=$has_components"
echo "external=$external"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "components<<EOF"
    echo "$compact"
    echo "EOF"
    echo "has_components=$has_components"
    echo "external=$external"
  } >> "$GITHUB_OUTPUT"
fi
