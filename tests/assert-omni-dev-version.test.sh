#!/usr/bin/env bash
# Tests for tests/assert-omni-dev-version.sh. Plain bash, no framework:
#   tests/assert-omni-dev-version.test.sh
# Exits non-zero if any case fails.
#
# The script is what every integration job ends on to show the omni-dev on PATH is
# the version it pinned, so what matters most is that it cannot pass for the wrong
# binary: a pin that is a prefix or a suffix of another release's number, a pin
# whose dots could stand for other characters, and an empty pin all fail here.
#
# `omni-dev` is a stub on a PATH that holds nothing else (the script uses only
# builtins), so the real binary on a developer's machine is never run. The stub
# prints $STUB_OUT, writes $STUB_ERR to stderr when set, and exits $STUB_EXIT.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/assert-omni-dev-version.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

BIN="$WORK/bin"
EMPTY="$WORK/empty"
mkdir "$BIN" "$EMPTY"
# An absolute interpreter: `#!/usr/bin/env bash` would need `env` on the stub's PATH.
cat >"$BIN/omni-dev" <<EOF
#!$BASH
[ "\$1" = --version ] || exit 64
[ -z "\${STUB_ERR:-}" ] || printf '%s\n' "\$STUB_ERR" >&2
printf '%s\n' "\$STUB_OUT"
exit "\${STUB_EXIT:-0}"
EOF
chmod +x "$BIN/omni-dev"

# run <PATH> <stub output> <stub exit status> [script arguments...]
# Sets STATUS, OUT (stdout) and ERR (stderr) of the script.
run() {
  local path=$1 out=$2 code=$3
  shift 3
  OUT="$(PATH="$path" STUB_OUT="$out" STUB_EXIT="$code" "$BASH" "$SCRIPT" "$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(<"$WORK/err")"
}

# accepts <pin> <version line>
accepts() {
  run "$BIN" "$2" 0 "$1"
  pass "accepts $1 for '$2'" test "$STATUS" -eq 0
  eq "  and says so" "ok   - omni-dev on PATH is $1 ($2)" "$OUT"
}

# rejects <pin> <version line>
rejects() {
  run "$BIN" "$2" 0 "$1"
  pass "rejects $1 for '$2'" test "$STATUS" -eq 1
  eq "  and says what it found" "::error::omni-dev on PATH is not $1 ($2); a poisoned cache?" "$OUT"
}

# --- the number must be the whole version -------------------------------------

# The shapes of a real `omni-dev --version`: a commit and date follow the number,
# or nothing does.
accepts 0.45.0 'omni-dev 0.45.0 (b5445b9 2026-10-03)'
accepts 0.28.0 'omni-dev 0.28.0'
# Every character of the pin is literal, so a `+` is not a quantifier.
accepts 0.32.0+build 'omni-dev 0.32.0+build (abc1234 2026-10-03)'

# A pin that is a prefix of another number, or a suffix of it.
rejects 0.4.1 'omni-dev 0.4.10'
rejects 0.45.0 'omni-dev 0.45.0.1'
rejects 0.32.0 'omni-dev 0.32.0-rc1'
rejects 1.2.3 'omni-dev 11.2.3 (abc1234 2026-10-03)'
# Another release, and a dot that must not stand for any other character.
rejects 0.44.0 'omni-dev 0.45.0 (b5445b9 2026-10-03)'
rejects 0.4.1 'omni-dev 0x4y1'
# The line starts with the program's name, and nothing comes before it.
rejects 0.45.0 'xomni-dev 0.45.0'
rejects 0.45.0 ''

# --- a binary that cannot report its version ----------------------------------

# Exiting non-zero fails even when what it printed looks right.
run "$BIN" 'omni-dev 0.45.0 (b5445b9 2026-10-03)' 3 0.45.0
pass "a binary that exits non-zero fails" test "$STATUS" -eq 1
eq "  and says the status and what it printed" \
  "::error::omni-dev --version exited 3 (expected 0.45.0): omni-dev 0.45.0 (b5445b9 2026-10-03)" "$OUT"

# Its stderr is left in the log: that is where such a binary says why.
OUT="$(PATH="$BIN" STUB_OUT='' STUB_EXIT=1 STUB_ERR='error while loading shared libraries: libasound.so.2' \
  "$BASH" "$SCRIPT" 0.45.0 2>"$WORK/err")"
STATUS=$?
ERR="$(<"$WORK/err")"
pass "a binary that prints nothing and fails also fails" test "$STATUS" -eq 1
eq "  and says it printed nothing" "::error::omni-dev --version exited 1 (expected 0.45.0): no output" "$OUT"
eq "  and its stderr is not swallowed" "error while loading shared libraries: libasound.so.2" "$ERR"

run "$EMPTY" '' 0 0.45.0
pass "no omni-dev on PATH fails" test "$STATUS" -eq 1
eq "  and says so" "::error::omni-dev is not on PATH (expected 0.45.0)" "$OUT"

# --- no version to expect -----------------------------------------------------

# An empty pin is a step that failed and exposed no `version` output. It must not
# pass whatever is on PATH, as `grep -F ""` would.
run "$BIN" 'omni-dev 0.45.0 (b5445b9 2026-10-03)' 0
pass "no version argument is a usage error" test "$STATUS" -eq 2
pass "  and is named" grep -q 'needs the version to expect' <<<"$OUT"

run "$BIN" 'omni-dev 0.45.0 (b5445b9 2026-10-03)' 0 ''
pass "an empty version argument is a usage error, not a match for anything" test "$STATUS" -eq 2
pass "  and is named" grep -q 'needs the version to expect' <<<"$OUT"

summary
