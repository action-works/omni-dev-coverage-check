#!/usr/bin/env bash
# Tests for tests/assert-patchcov-version.sh. Plain bash, no framework:
#   tests/assert-patchcov-version.test.sh
# Exits non-zero if any case fails.
#
# The script is what every integration job ends on to show the patchcov on PATH is
# the version it pinned, so what matters most is that it cannot pass for the wrong
# binary: a pin that is a prefix or a suffix of another release's number, a pin
# whose dots could stand for other characters, and an empty pin all fail here.
#
# `patchcov` is a stub on a PATH that holds nothing else (the script uses only
# builtins), so the real binary on a developer's machine is never run. The stub
# prints $STUB_OUT, writes $STUB_ERR to stderr when set, and exits $STUB_EXIT.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/assert-patchcov-version.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

BIN="$WORK/bin"
EMPTY="$WORK/empty"
mkdir "$BIN" "$EMPTY"
# An absolute interpreter: `#!/usr/bin/env bash` would need `env` on the stub's PATH.
cat >"$BIN/patchcov" <<EOF
#!$BASH
[ "\$1" = --version ] || exit 64
[ -z "\${STUB_ERR:-}" ] || printf '%s\n' "\$STUB_ERR" >&2
printf '%s\n' "\$STUB_OUT"
exit "\${STUB_EXIT:-0}"
EOF
chmod +x "$BIN/patchcov"

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
  eq "  and says so" "ok   - patchcov on PATH is $1 ($2)" "$OUT"
}

# rejects <pin> <version line>
rejects() {
  run "$BIN" "$2" 0 "$1"
  pass "rejects $1 for '$2'" test "$STATUS" -eq 1
  eq "  and says what it found" "::error::patchcov on PATH is not $1 ($2); a poisoned cache?" "$OUT"
}

# --- the number must be the whole version -------------------------------------

# The shapes of a real `patchcov --version`: a commit and date follow the number,
# or nothing does.
accepts 0.1.1 'patchcov 0.1.1 (b5445b9 2026-10-03)'
accepts 0.28.0 'patchcov 0.28.0'
# Every character of the pin is literal, so a `+` is not a quantifier.
accepts 0.32.0+build 'patchcov 0.32.0+build (abc1234 2026-10-03)'

# A pin that is a prefix of another number, or a suffix of it.
rejects 0.4.1 'patchcov 0.4.10'
rejects 0.1.1 'patchcov 0.1.1.1'
rejects 0.32.0 'patchcov 0.32.0-rc1'
rejects 1.2.3 'patchcov 11.2.3 (abc1234 2026-10-03)'
# Another release, and a dot that must not stand for any other character.
rejects 0.1.0 'patchcov 0.1.1 (b5445b9 2026-10-03)'
rejects 0.4.1 'patchcov 0x4y1'
# The line starts with the program's name, and nothing comes before it.
rejects 0.1.1 'xpatchcov 0.1.1'
rejects 0.1.1 ''

# --- a binary that cannot report its version ----------------------------------

# Exiting non-zero fails even when what it printed looks right.
run "$BIN" 'patchcov 0.1.1 (b5445b9 2026-10-03)' 3 0.1.1
pass "a binary that exits non-zero fails" test "$STATUS" -eq 1
eq "  and says the status and what it printed" \
  "::error::patchcov --version exited 3 (expected 0.1.1): patchcov 0.1.1 (b5445b9 2026-10-03)" "$OUT"

# Its stderr is left in the log: that is where such a binary says why.
OUT="$(PATH="$BIN" STUB_OUT='' STUB_EXIT=1 STUB_ERR='error while loading shared libraries: libasound.so.2' \
  "$BASH" "$SCRIPT" 0.1.1 2>"$WORK/err")"
STATUS=$?
ERR="$(<"$WORK/err")"
pass "a binary that prints nothing and fails also fails" test "$STATUS" -eq 1
eq "  and says it printed nothing" "::error::patchcov --version exited 1 (expected 0.1.1): no output" "$OUT"
eq "  and its stderr is not swallowed" "error while loading shared libraries: libasound.so.2" "$ERR"

run "$EMPTY" '' 0 0.1.1
pass "no patchcov on PATH fails" test "$STATUS" -eq 1
eq "  and says so" "::error::patchcov is not on PATH (expected 0.1.1)" "$OUT"

# --- no version to expect -----------------------------------------------------

# An empty pin is a step that failed and exposed no `version` output. It must not
# pass whatever is on PATH, as `grep -F ""` would.
run "$BIN" 'patchcov 0.1.1 (b5445b9 2026-10-03)' 0
pass "no version argument is a usage error" test "$STATUS" -eq 2
pass "  and is named" grep -q 'needs the version to expect' <<<"$OUT"

run "$BIN" 'patchcov 0.1.1 (b5445b9 2026-10-03)' 0 ''
pass "an empty version argument is a usage error, not a match for anything" test "$STATUS" -eq 2
pass "  and is named" grep -q 'needs the version to expect' <<<"$OUT"

summary
