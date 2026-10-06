#!/usr/bin/env bash
# Contract checks for the default pin, isolated cache and source-install command.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"
has 'default is first usable binary release' "$(input_block version)" "default: '0.1.1'"
CACHE="$(step_block 'Cache patchcov binary')"
has 'cache stores only patchcov' "$CACHE" 'path: ~/.cargo/bin/patchcov'
has 'cache key cannot restore an omni-dev entry' "$CACHE" '}patchcov-'
lacks 'no omni-dev binary path' "$CACHE" '/omni-dev'
SOURCE="$(step_run 'Install patchcov from source')"
mkdir "$WORK/bin"
cat > "$WORK/bin/cargo" <<'STUB'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
[ -z "${VERSION+x}" ] || exit 9
exit "${CARGO_STATUS:-0}"
STUB
chmod +x "$WORK/bin/cargo"
OUT="$(PATH="$WORK/bin:$PATH" VERSION=0.1.1 bash -eo pipefail -c "$SOURCE")"
eq 'source install succeeds' 0 "$?"
has 'source installs pinned patchcov, with VERSION removed from cargo environment' "$OUT" $'<install>\n<patchcov>\n<--version>\n<0.1.1>'
PATH="$WORK/bin:$PATH" VERSION=0.1.1 CARGO_STATUS=7 bash -eo pipefail -c "$SOURCE" > /dev/null
eq 'source install propagates failure' 7 "$?"
WARNING="$(step_block 'Warn about legacy coverage settings')"
# shellcheck disable=SC2016
has 'warning script runs from action path' "$WARNING" 'ACTION_PATH: ${{ github.action_path }}'
has 'warning is wired into the action' "$WARNING" 'scripts/check-legacy-config.sh'
summary
