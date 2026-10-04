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
# Writes `components` and `has_components` (true|false) to GITHUB_OUTPUT when
# set; always prints them. An empty list is not an error: the repo simply has
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
if ! count="$(jq -e 'if type == "array" then length else error("not an array") end' <<<"$components" 2>/dev/null)"; then
  echo "components is not a JSON array: $components" >&2
  exit 2
fi

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

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "components<<EOF"
    echo "$compact"
    echo "EOF"
    echo "has_components=$has_components"
  } >> "$GITHUB_OUTPUT"
fi
