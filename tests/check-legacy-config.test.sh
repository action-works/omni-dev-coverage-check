#!/usr/bin/env bash
# Run the actual warning script in a caller repository, including marker discovery.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
mkdir "$WORK/repo"
git -C "$WORK/repo" init -q
run() {
  OUT="$(cd "$WORK/repo" && OMNI_DEV_CONFIG_DIR="${CONFIG-}" bash "$ROOT/scripts/check-legacy-config.sh")"
  STATUS=$?
}
run
eq 'no old settings: succeeds silently' 0 "$STATUS"
eq 'no old settings: no warning' '' "$OUT"
mkdir "$WORK/repo/.omni-dev"
printf 'coverage: {}\n' > "$WORK/repo/.omni-dev/coverage.yaml"
run
has 'legacy file: warns about ignored exclusions' "$OUT" 'Patchcov ignores them'
has 'legacy file: tells caller where to move it' "$OUT" '.patchcov/config.yaml'
rm "$WORK/repo/.omni-dev/coverage.yaml"
CONFIG=$'hostile\n::error::data' run
has 'legacy environment: warns' "$OUT" 'OMNI_DEV_CONFIG_DIR'
lacks 'legacy environment: value stays private' "$OUT" 'hostile'
printf '// omni-dev: coverage ignore\n' > "$WORK/repo/lib.rs"
git -C "$WORK/repo" add lib.rs
run
has 'tracked old source marker: warns' "$OUT" 'omni-dev coverage source markers'
printf '// patchcov: coverage ignore\n' > "$WORK/repo/lib.rs"
run
eq 'migrated marker: silent' '' "$OUT"
printf 'omni-dev: coverage ignore\n' > "$WORK/repo/README.md"
git -C "$WORK/repo" add README.md
run
eq 'migration prose: no warning' '' "$OUT"
summary
