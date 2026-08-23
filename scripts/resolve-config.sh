#!/usr/bin/env bash
# Parse .deploytrack.yaml into matrix JSON for reusable workflows.
# Usage: resolve-config.sh [path-to-.deploytrack.yaml]
# Writes `components` and `branches` to GITHUB_OUTPUT when set; always prints them.
#
# Missing file or empty components/branches fall back to org defaults that match
# the current backend/frontend templates.

set -euo pipefail

CONFIG_FILE="${1:-.deploytrack.yaml}"

DEFAULT_COMPONENTS='[{"name":"backend","path":"./backend","dockerfile":"Dockerfile","image_suffix":"backend"},{"name":"frontend","path":"./frontend","dockerfile":"Dockerfile","image_suffix":"frontend"}]'
DEFAULT_BRANCHES='["dev","staging","production"]'

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (mikefarah/yq)" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "No $CONFIG_FILE — using org defaults" >&2
  components="$DEFAULT_COMPONENTS"
  branches="$DEFAULT_BRANCHES"
else
  if ! yq -e '.' "$CONFIG_FILE" >/dev/null; then
    echo "failed to parse $CONFIG_FILE" >&2
    exit 1
  fi

  raw_count="$(yq -e '(.components // []) | length' "$CONFIG_FILE")"
  if [[ "$raw_count" -eq 0 ]]; then
    echo "$CONFIG_FILE has no components — using org defaults" >&2
    components="$DEFAULT_COMPONENTS"
  else
    missing="$(yq -e '[.components[] | select(.name == null or .name == "")] | length' "$CONFIG_FILE")"
    if [[ "$missing" -gt 0 ]]; then
      echo "every component must have a name" >&2
      exit 1
    fi
    components="$(yq -o=json -I=0 '
      .components
      | map({
          name: .name,
          path: ((.path | select(length > 0)) // "."),
          dockerfile: ((.dockerfile | select(length > 0)) // "Dockerfile"),
          image_suffix: ((.image_suffix | select(length > 0)) // .name)
        })
    ' "$CONFIG_FILE")"
  fi

  branch_count="$(yq -e '(.branches // []) | length' "$CONFIG_FILE")"
  if [[ "$branch_count" -eq 0 ]]; then
    branches="$DEFAULT_BRANCHES"
  else
    branches="$(yq -o=json -I=0 '.branches' "$CONFIG_FILE")"
  fi
fi

echo "components=$components"
echo "branches=$branches"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "components<<EOF"
    echo "$components"
    echo "EOF"
    echo "branches<<EOF"
    echo "$branches"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi
