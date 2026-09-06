#!/usr/bin/env bash
# Parse .deploytrack.yaml into matrix JSON for reusable workflows.
# Usage: resolve-config.sh [path-to-.deploytrack.yaml]
# Writes `components` and `branches` to GITHUB_OUTPUT when set; always prints them.
#
# Missing file, empty components, or components.infer: true → Compose inference
# from the first file at repo root (cwd): docker-compose.yml, docker-compose.yaml,
# compose.yml, compose.yaml. Services with build: become components; otherwise
# a single app component at ".".

set -euo pipefail

CONFIG_FILE="${1:-.deploytrack.yaml}"
DEFAULT_BRANCHES='["dev","production"]'
APP_FALLBACK='[{"name":"app","path":".","dockerfile":"Dockerfile","image_suffix":"app"}]'

if ! command -v yq >/dev/null 2>&1; then
  echo "yq is required (mikefarah/yq)" >&2
  exit 1
fi

app_fallback() {
  echo "$APP_FALLBACK"
}

# First Compose file at repo root wins; no merge.
# yq has no if/then/else — use select + //.
infer_components_from_compose() {
  local files=(docker-compose.yml docker-compose.yaml compose.yml compose.yaml)
  local f parsed
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      parsed="$(yq -o=json -I=0 '
        (.services // {})
        | to_entries
        | map(select(.value.build != null))
        | map({
            "name": .key,
            "path": (
              (.value.build | select(kind == "scalar" and . != "")) //
              (.value.build.context | select(. != null and . != "")) //
              "."
            ),
            "dockerfile": (
              (.value.build | select(kind == "map") | .dockerfile | select(. != null and . != "")) //
              "Dockerfile"
            ),
            "image_suffix": .key
          })
      ' "$f")"
      if [[ -z "$parsed" || "$parsed" == "null" || "$parsed" == "[]" ]]; then
        app_fallback
      else
        echo "$parsed"
      fi
      return
    fi
  done
  app_fallback
}

normalize_explicit_components() {
  yq -o=json -I=0 '
    .components
    | map(
        (select(kind == "scalar") | {"name": ., "path": ".", "dockerfile": "Dockerfile", "image_suffix": .}) // .
      )
    | map(
        (
          ((.path // "") | select(. != "")) // "."
        ) as $path
        | (
            ((.name // "") | select(. != "")) //
            (
              $path
              | sub("/+$"; "")
              | split("/")
              | map(select(. != "" and . != "."))
              | .[-1] // "app"
            )
          ) as $name
        | {
            "name": $name,
            "path": $path,
            "dockerfile": (((.dockerfile // "") | select(. != "")) // "Dockerfile"),
            "image_suffix": (((.image_suffix // "") | select(. != "")) // $name)
          }
      )
  ' "$CONFIG_FILE"
}

should_infer_components() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    return 0
  fi
  local comp_type
  comp_type="$(yq -r '.components | type' "$CONFIG_FILE")"
  case "$comp_type" in
    "!!null")
      return 0
      ;;
    "!!map")
      # {infer: true} is a mapping, not a list — do not use | length.
      return 0
      ;;
    "!!seq")
      local count
      count="$(yq -e '.components | length' "$CONFIG_FILE")"
      [[ "$count" -eq 0 ]]
      ;;
    *)
      echo "components must be a list of objects/names or {infer: true}, not a string" >&2
      exit 1
      ;;
  esac
}

if [[ -f "$CONFIG_FILE" ]]; then
  if ! yq -e '.' "$CONFIG_FILE" >/dev/null; then
    echo "failed to parse $CONFIG_FILE" >&2
    exit 1
  fi
fi

if should_infer_components; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "No $CONFIG_FILE — inferring components from Compose" >&2
  else
    echo "$CONFIG_FILE has no explicit component list — inferring from Compose" >&2
  fi
  components="$(infer_components_from_compose)"
else
  components="$(normalize_explicit_components)"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  branches="$DEFAULT_BRANCHES"
else
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
