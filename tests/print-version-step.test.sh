#!/usr/bin/env bash
# Tests for the "Print omni-dev version" step of action.yml. Plain bash, no framework:
#   tests/print-version-step.test.sh
# Exits non-zero if any case fails.
#
# The step runs the installed omni-dev once. A pre-built Linux binary that needs a newer
# glibc than the runner has is stopped by the dynamic loader, which says only
# "version `GLIBC_2.38' not found" (#67), so when that is what it said, the step names the
# glibc the binary wants, the one the runner has and the two ways out. Anything else that
# stops the binary is shown as before and keeps its exit status.
#
# The loader's wording is what the step matches, so it is replayed from what the loader
# printed: tests/fixtures/omni-dev-loader/, one file per binary (`exit=<status>`, then the
# output). `omni-dev` is a stub that replays a fixture and `getconf` a stub that names the
# runner's glibc, so this runs anywhere and never runs a real binary.
#
# The cases that matter most are the ones that pick the version to ask for. The x86_64
# binary also logs a WEAK `GLIBC_2.39`, which is optional and did not stop it, so 2.38 is
# the answer; the ARM64 binary names 2.39 before 2.38, so the answer is the newest and not
# the first. Each of those has a control that differs in one line.

# The ${{ }} patterns and the backquotes in the loader text are literal text, not expansions.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
FIXTURES="$ROOT/tests/fixtures/omni-dev-loader"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

STEP='Print omni-dev version'
SCRIPT="$(step_run "$STEP")" || exit 1
BLOCK="$(step_block "$STEP")" || exit 1

# The stubs. omni-dev replays $STUB_FIXTURE: the first line is `exit=<status>`, the rest is
# what it printed, on stdout for a success and on stderr for a failure, as the loader and a
# failing program do. getconf answers `GNU_LIBC_VERSION` with $STUB_GLIBC, and fails when
# that is empty, as it does on a system that has no glibc.
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/omni-dev" <<'EOF'
#!/usr/bin/env bash
code="$(head -n 1 "$STUB_FIXTURE")"
code="${code#exit=}"
if [ "$code" = 0 ]; then sed 1d "$STUB_FIXTURE"; else sed 1d "$STUB_FIXTURE" >&2; fi
exit "$code"
EOF
cat >"$BIN/getconf" <<'EOF'
#!/usr/bin/env bash
[ "$1" = GNU_LIBC_VERSION ] || exit 1
[ -n "${STUB_GLIBC:-}" ] || exit 1
echo "$STUB_GLIBC"
EOF
chmod +x "$BIN/omni-dev" "$BIN/getconf"

# fixture <name> <exit status> <line>...: writes a fixture of this test's own.
fixture() {
  local name=$1 code=$2
  shift 2
  { echo "exit=$code"; printf '%s\n' "$@"; } >"$WORK/$name.txt"
}

# run_step <fixture file> [glibc]: runs the step as the runner would (bash -eo pipefail) with
# the variables its env: block fills. Sets STATUS, LOG (stdout and stderr together) and
# ERRORS (how many `::error::` lines it printed).
run_step() {
  local fixture=$1 glibc=${2-glibc 2.35}
  LOG="$(PATH="$BIN:$PATH" STUB_FIXTURE="$fixture" STUB_GLIBC="$glibc" OMNI_DEV_VERSION=0.45.0 OS=Linux ARCH=X64 \
    bash --noprofile --norc -eo pipefail -c "$SCRIPT" 2>&1)"
  STATUS=$?
  ERRORS="$(grep -c '^::error::' <<<"$LOG" || true)"
}

X86="$FIXTURES/0.45.0-x86_64-glibc-2.35.txt"
ARM="$FIXTURES/0.46.0-aarch64-glibc-2.35.txt"

# --- what the loader printed ----------------------------------------------------------------

# A fixture that says something else would make every case below replay nothing: each must
# be a failure that holds a non-weak missing GLIBC version, and the x86_64 one a weak one too.
for fx in "$X86" "$ARM"; do
  eq "fixture $(basename "$fx"): it is a failure" "exit=1" "$(head -n 1 "$fx")"
  pass "fixture $(basename "$fx"): it holds a missing GLIBC version" grep -q ": version \`GLIBC_" "$fx"
done
pass "fixture x86_64: it also holds a weak one, which did not stop the binary" grep -q ": weak version \`GLIBC_" "$X86"

# --- a binary the runner's glibc is too old for ---------------------------------------------

run_step "$X86"
eq "x86_64: the step fails, with the binary's own status" 1 "$STATUS"
has "x86_64: what the loader said is still in the log" "$LOG" "version \`GLIBC_2.38' not found"
eq "x86_64: it logs one error" 1 "$ERRORS"
has "x86_64: the error names the release and the platform" "$LOG" \
  "::error::omni-dev 0.45.0 cannot run on this runner (Linux X64)"
has "x86_64: it names the glibc the binary needs, the non-weak one" "$LOG" "it needs glibc 2.38 or newer"
lacks "x86_64: and not the weak 2.39 the loader also listed" "$LOG" "needs glibc 2.39"
has "x86_64: it says what the runner has" "$LOG" "and the runner has glibc 2.35."
has "x86_64: the first way out is a newer runner image" "$LOG" \
  "Use a runner image with glibc 2.38 or newer (ubuntu-24.04, or ubuntu-24.04-arm)"
has "x86_64: the second way out is to build from source" "$LOG" \
  "set 'use-prebuilt-binary: false' to build omni-dev from source."

# The ARM64 binary names 2.39 first and 2.38 second: the newest is the answer, and not the
# first line or the last.
run_step "$ARM"
eq "ARM64: the step fails, with the binary's own status" 1 "$STATUS"
eq "ARM64: it logs one error" 1 "$ERRORS"
has "ARM64: it names the newest of the missing versions" "$LOG" "it needs glibc 2.39 or newer"
lacks "ARM64: and not the older one it listed second" "$LOG" "needs glibc 2.38"

# The order of the lines does not decide it: the same two lines the other way round.
fixture reversed 1 \
  "omni-dev: /lib/aarch64-linux-gnu/libc.so.6: version \`GLIBC_2.38' not found (required by omni-dev)" \
  "omni-dev: /lib/aarch64-linux-gnu/libc.so.6: version \`GLIBC_2.39' not found (required by omni-dev)"
run_step "$WORK/reversed.txt"
has "the order of the lines does not decide it: 2.39 either way" "$LOG" "it needs glibc 2.39 or newer"

# The versions are compared as numbers, not as text: 2.9 sorts after 2.38 as a string.
fixture numeric 1 \
  "omni-dev: /lib/libc.so.6: version \`GLIBC_2.9' not found (required by omni-dev)" \
  "omni-dev: /lib/libc.so.6: version \`GLIBC_2.38' not found (required by omni-dev)" \
  "omni-dev: /lib/libc.so.6: version \`GLIBC_2.4' not found (required by omni-dev)"
run_step "$WORK/numeric.txt"
has "versions are compared as numbers: 2.38 beats 2.9 and 2.4" "$LOG" "it needs glibc 2.38 or newer"

fixture three 1 \
  "omni-dev: /lib/libc.so.6: version \`GLIBC_2.38.1' not found (required by omni-dev)" \
  "omni-dev: /lib/libc.so.6: version \`GLIBC_2.38' not found (required by omni-dev)"
run_step "$WORK/three.txt"
has "a three-part version is read whole" "$LOG" "it needs glibc 2.38.1 or newer"

# A weak version alone is not what stopped it: with nothing else to name, the step has no
# glibc to ask for and says nothing of one.
fixture weak-only 1 \
  "omni-dev: /lib/x86_64-linux-gnu/libc.so.6: weak version \`GLIBC_2.39' not found (required by omni-dev)"
run_step "$WORK/weak-only.txt"
eq "only a weak version: the status is kept" 1 "$STATUS"
eq "only a weak version: no glibc error is made up" 0 "$ERRORS"
has "only a weak version: what the loader said is shown" "$LOG" "weak version \`GLIBC_2.39' not found"

# --- the runner's own glibc is not always readable ------------------------------------------

run_step "$X86" ""
eq "no getconf answer: the step still fails the same way" 1 "$STATUS"
has "no getconf answer: it says the runner has an older glibc, and still what is needed" "$LOG" \
  "it needs glibc 2.38 or newer, and the runner has an older glibc."
has "no getconf answer: both ways out are still given" "$LOG" "or set 'use-prebuilt-binary: false'"

run_step "$X86" "glibc 2.31"
has "another runner glibc is the one named" "$LOG" "and the runner has glibc 2.31."

# --- a binary that stops for another reason, and one that runs ----------------------------------

fixture other 3 "omni-dev: error while loading shared libraries: libasound.so.2: cannot open shared object file"
run_step "$WORK/other.txt"
eq "another loader failure: the binary's own status is kept" 3 "$STATUS"
has "another loader failure: what it said is shown" "$LOG" "libasound.so.2: cannot open shared object file"
eq "another loader failure: no glibc error is made up" 0 "$ERRORS"

# A libstdc++ that is too old says GLIBCXX, which is not a glibc problem.
fixture cxx 1 "omni-dev: /lib/x86_64-linux-gnu/libstdc++.so.6: version \`GLIBCXX_3.4.30' not found (required by omni-dev)"
run_step "$WORK/cxx.txt"
eq "a GLIBCXX failure: the status is kept" 1 "$STATUS"
eq "a GLIBCXX failure: it is not reported as a glibc one" 0 "$ERRORS"

fixture ok 0 "omni-dev 0.46.0 (b5445b9 2026-10-03)"
run_step "$WORK/ok.txt"
eq "a binary that runs: the step succeeds" 0 "$STATUS"
eq "a binary that runs: it prints the version, as the step always did" "omni-dev 0.46.0 (b5445b9 2026-10-03)" "$LOG"

# Even when it runs and prints a loader-like word, nothing is made of a success.
fixture ok-noisy 0 "omni-dev 0.46.0 (b5445b9 2026-10-03)" "note: version \`GLIBC_2.99' not found is only text here"
run_step "$WORK/ok-noisy.txt"
eq "a binary that runs: the output is not searched" 0 "$ERRORS"

# --- the wiring around the script -----------------------------------------------------------

has "shell: the step runs under bash, as these cases do" "$BLOCK" "      shell: bash"
has "env: the release comes from the resolved version" "$BLOCK" \
  '        OMNI_DEV_VERSION: ${{ steps.resolve-version.outputs.version }}'
has "env: the OS is the runner's" "$BLOCK" '        OS: ${{ runner.os }}'
has "env: the architecture is the runner's" "$BLOCK" '        ARCH: ${{ runner.arch }}'
# Values reach the script through env:, never as an expression in it (#39).
eq "script: it holds no expression" "" "$(grep -n -F '${{' <<<"$SCRIPT" || true)"

summary
