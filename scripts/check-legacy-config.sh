#!/usr/bin/env bash
# Advisory only: patchcov does not read omni-dev's coverage configuration/markers.
set -euo pipefail
legacy=()
if [ -f .omni-dev/coverage.yaml ]; then legacy+=('.omni-dev/coverage.yaml'); fi
if [ -n "${OMNI_DEV_CONFIG_DIR:-}" ]; then legacy+=('OMNI_DEV_CONFIG_DIR'); fi
# Search tracked source, not docs/workflows that explain migration. Do not print
# caller-controlled paths or config contents into workflow commands.
if git grep -Iq -E 'omni-dev:[[:space:]]+coverage[[:space:]]+(ignore|tolerate)' -- \
  '*.rs' '*.py' '*.go' '*.c' '*.h' '*.cpp' '*.js' '*.ts' '*.tsx' '*.java' '*.kt' '*.swift' '*.rb'; then
  legacy+=('omni-dev coverage source markers')
fi
if [ "${#legacy[@]}" -gt 0 ]; then
  echo "::warning::Legacy coverage settings detected: ${legacy[*]}. Patchcov ignores them, so exclusions and measured coverage may change. Migrate .omni-dev/coverage.yaml to .patchcov/config.yaml, OMNI_DEV_CONFIG_DIR to PATCHCOV_CONFIG_DIR, and source markers to 'patchcov: coverage ignore' or 'patchcov: coverage tolerate'. See the action README's v2 migration instructions."
fi
