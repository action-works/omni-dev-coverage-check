#!/usr/bin/env bash
# Tests for the "Check omni-dev supports the flags this run uses" step of action.yml.
# Plain bash, no framework:
#   tests/guard-step.test.sh
# Exits non-zero if any case fails.
#
# The integration legs run the guard against real releases, so they cannot reach a help
# text no release has: a longer flag name (`--output-file`) or prose that mentions a flag.
# This runs the step against a stub `omni-dev` whose help text each case chooses, and
# asserts which `::error::` lines the step prints and how it exits. The step's script is
# read out of action.yml itself, so renaming the step or moving its `run:` block fails here,
# by name, rather than leaving a test of a copy.
#
# The option lines below have the layout of the real `omni-dev coverage diff --help` (clap:
# an optional short flag, the long flag, a value, the description on the lines after), and
# tests/fixtures/omni-dev-help/ holds the real help of the releases either side of each
# floor, so the pattern is also held to what omni-dev prints. Refresh one with
#   omni-dev coverage diff --help > tests/fixtures/omni-dev-help/<version>.txt
# Every failing case has a control that differs only in the help text.
#
# What this does not reach: the step's `if:`, which decides whether it runs at all. The
# script calls `--help` whatever the event, so the "flag not needed" cases show it does
# not demand a flag the run does not use, not that it is skipped. The `output-flag` job
# of integration.yml runs on every event and covers the `if:`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "ok   - $1"
}

bad() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  [ -z "${2:-}" ] || echo "       $2"
}

# eq <name> <expected> <actual>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# has <name> <text> <fragment>: the text contains the fragment (a fixed string).
has() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "no '$3' in: $2"; fi
}

# lacks <name> <text> <fragment>
lacks() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected '$3' in: $2"; fi
}

# step_run <step name>: the step's `run: |` body, dedented. The guard keeps `run` last,
# so the body ends at the first line indented less than it.
step_run() {
  awk -v name="$1" '
    $0 == "    - name: " name { in_step = 1; next }
    in_step && /^    - name:/ { exit }
    in_step && $0 == "      run: |" { in_run = 1; next }
    in_run && /^        / { print substr($0, 9); next }
    in_run && $0 == "" { print ""; next }
    in_run { exit }
  ' "$ACTION"
}

GUARD="$(step_run 'Check omni-dev supports the flags this run uses')"
if [ -z "$GUARD" ]; then
  echo "FAIL - could not read the guard step out of action.yml"
  exit 1
fi
# step_run stops at the first line indented less than the body, so a key or comment placed
# after `run:` would cut the script short and every case below would test the stump.
# shellcheck disable=SC2016 # the script's own last line, to be compared as text
if [ "$(tail -n1 <<<"$GUARD")" != 'exit "$status"' ]; then
  echo "FAIL - the guard step's script does not end where this test expects; read only part of it?"
  exit 1
fi

# The stub answers the two calls the step makes. A failing `--help` is what an omni-dev
# below 0.29.0 does: no `coverage` subcommand, so clap exits 2.
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/omni-dev" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$OMNI_DEV_LOG"
case "$*" in
  'coverage diff --help')
    if [ "${FAKE_HELP_STATUS:-0}" != 0 ]; then
      echo "error: unrecognized subcommand 'coverage'" >&2
      exit "$FAKE_HELP_STATUS"
    fi
    printf '%s\n' "$FAKE_HELP"
    ;;
  --version)
    echo "$FAKE_VERSION"
    ;;
  *)
    echo "stub omni-dev: unexpected arguments: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$BIN/omni-dev"

# --- help texts --------------------------------------------------------------------

HELP_HEAD="$(
  cat <<'EOF'
Analyses diff/patch coverage from a per-line report and a git diff

Usage: omni-dev coverage diff [OPTIONS] --report <PATH>

Options:
      --report <PATH>
          Head coverage report (lcov / llvm-cov-json / cobertura); repeat once per shard.

      --fail-under-patch <PCT>
          Exit non-zero when patch coverage is below this percentage.
EOF
)"
HELP_TAIL="$(
  cat <<'EOF'
      --ignore-filename-regex <REGEX>
          Repeatable. Matching is unanchored, the same semantics as `cargo llvm-cov --ignore-filename-regex`, and is applied after `--strip-prefix` normalisation.

  -h, --help
          Print help (see a summary with '-h')
EOF
)"

# help_with <option block>: the head, the block, the tail, as `--help` would print them.
help_with() {
  printf '%s\n\n%s\n\n%s\n' "$HELP_HEAD" "$1" "$HELP_TAIL"
}

# The real definition lines, as 0.45.0 prints them.
OUTPUT_OPTION=$'  -o, --output <OUTPUT>\n          Output format: md or json.'
OUTPUT_LONG_ONLY=$'      --output <OUTPUT>\n          Output format: md or json.'
OUTPUT_NO_VALUE=$'  -o, --output\n          Output format: md or json.'
# How clap writes an option that needs `=` or takes an optional value.
OUTPUT_EQUALS=$'      --output=<OUTPUT>\n          Output format: md or json.'
OUTPUT_OPTIONAL=$'  -o, --output[=<OUTPUT>]\n          Output format: md or json.'
LINES_OPTION=$'      --fail-under-lines <PCT>\n          Exit non-zero when the line total is below this percentage.'
LINES_OPTIONAL=$'      --fail-under-lines[=<PCT>]\n          Exit non-zero when the line total is below this percentage.'

# Text that holds the flag name without defining the flag.
OUTPUT_FILE_ONLY=$'      --output-file <PATH>\n          Write the diff to a file.'
OUTPUT_PROSE=$'      --report-format <FORMAT>\n          Format of every report; it does not change --output, which is the diff.'
LINES_PER_FILE_ONLY=$'      --fail-under-lines-per-file <PCT>\n          Exit non-zero when any file is below this percentage.'
LINES_PROSE=$'      --fail-under-patch <PCT>\n          Unlike --fail-under-lines, this gates only the added lines.'

# --- running the step ----------------------------------------------------------------

# run_guard <event> <run-coverage> <fail-under-lines> <help text> [version] [help status]:
# runs the step as the runner would, with the inputs it reads in its environment. Sets
# STATUS (the step's exit status), OUT (its output), ERRORS (its `::error::` lines),
# N_ERRORS and CALLS (what it asked omni-dev, one call per line).
run_guard() {
  local event=$1 run_coverage=$2 gate=$3 help=$4 version=${5:-omni-dev 0.45.0 (2de88c54 2026-10-03)} help_status=${6:-0} dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  : >"$dir/omni-dev.log"
  OUT="$(
    PATH="$BIN:$PATH" OMNI_DEV_LOG="$dir/omni-dev.log" FAKE_HELP="$help" FAKE_VERSION="$version" \
      FAKE_HELP_STATUS="$help_status" EVENT_NAME="$event" RUN_COVERAGE="$run_coverage" \
      FAIL_UNDER_LINES="$gate" bash --noprofile --norc -eo pipefail -c "$GUARD" 2>&1
  )"
  STATUS=$?
  ERRORS="$(grep '^::error::' <<<"$OUT" || true)"
  N_ERRORS="$(grep -c '^::error::' <<<"$OUT" || true)"
  CALLS="$(cat "$dir/omni-dev.log")"
}

OUTPUT_MSG="has no 'coverage diff --output'"
LINES_MSG="has no 'coverage diff --fail-under-lines'"

# expect_pass <name>: the step succeeded and printed no error.
expect_pass() {
  eq "$1: the step succeeds" 0 "$STATUS"
  eq "$1: it prints no error" 0 "$N_ERRORS"
}

# expect_only <name> <message>: the step failed with exactly one error, the given one.
expect_only() {
  eq "$1: the step fails" 1 "$STATUS"
  eq "$1: it prints one error" 1 "$N_ERRORS"
  has "$1: it is the expected one" "$ERRORS" "$2"
}

# --- --output: a pull request, whatever the mode ------------------------------------------

run_guard pull_request true '' "$(help_with "$OUTPUT_OPTION")"
expect_pass "--output defined with a short flag"

run_guard pull_request true '' "$(help_with "$OUTPUT_LONG_ONLY")"
expect_pass "--output defined as a long flag only"

run_guard pull_request true '' "$(help_with "$OUTPUT_NO_VALUE")"
expect_pass "--output defined with no value"

run_guard pull_request true '' "$(help_with "$OUTPUT_EQUALS")"
expect_pass "--output defined with a value after '='"

run_guard pull_request true '' "$(help_with "$OUTPUT_OPTIONAL")"
expect_pass "--output defined with an optional value"

run_guard pull_request true '' "$(help_with "$OUTPUT_FILE_ONLY")"
expect_only "only --output-file" "$OUTPUT_MSG"

run_guard pull_request true '' "$(help_with "$OUTPUT_PROSE")"
expect_only "only prose that mentions --output" "$OUTPUT_MSG"

run_guard pull_request true '' "$(help_with "$LINES_OPTION")"
expect_only "a help text with no --output" "$OUTPUT_MSG"

# The message the user reads: the omni-dev found (its number, commit and date, as
# `omni-dev --version` prints them), the floor and the way out.
run_guard pull_request true '' "$(help_with "$OUTPUT_FILE_ONLY")" "omni-dev 0.31.0 (0a1b2c3d 2025-01-02)"
has "the --output error names the omni-dev found" "$ERRORS" "::error::omni-dev 0.31.0 (0a1b2c3d 2025-01-02) has no"
has "the --output error names the floor" "$ERRORS" "0.32.0 or later"
has "the --output error says how to fix it" "$ERRORS" "set 'version' to 0.32.0 or later, or to 'latest'"

# --- --fail-under-lines: thin mode with the line gate on ----------------------------------

run_guard push false 80 "$(help_with "$LINES_OPTION")"
expect_pass "--fail-under-lines defined"

run_guard push false 80 "$(help_with "$LINES_OPTIONAL")"
expect_pass "--fail-under-lines defined with an optional value"

run_guard push false 80 "$(help_with "$LINES_PER_FILE_ONLY")"
expect_only "only --fail-under-lines-per-file" "$LINES_MSG"

run_guard push false 80 "$(help_with "$LINES_PROSE")"
expect_only "only prose that mentions --fail-under-lines" "$LINES_MSG"

run_guard push false 80 "$(help_with "$OUTPUT_OPTION")"
expect_only "a help text with no --fail-under-lines" "$LINES_MSG"

run_guard push false 80 "$(help_with "$LINES_PER_FILE_ONLY")" "omni-dev 0.44.0 (0a1b2c3d 2025-01-02)"
has "the --fail-under-lines error names the omni-dev found" "$ERRORS" "::error::omni-dev 0.44.0 (0a1b2c3d 2025-01-02) has no"
has "the --fail-under-lines error says how to fix it" "$ERRORS" "or set 'fail-under-lines' to an empty string to run thin mode without a line gate"

# --- both, and each independent of the other ----------------------------------------------

run_guard pull_request false 80 "$(help_with "$OUTPUT_OPTION"$'\n\n'"$LINES_OPTION")"
expect_pass "both flags defined"

run_guard pull_request false 80 "$(help_with "$OUTPUT_FILE_ONLY"$'\n\n'"$LINES_PER_FILE_ONLY")"
eq "neither flag defined: the step fails" 1 "$STATUS"
eq "neither flag defined: it reports both, not just the first" 2 "$N_ERRORS"
has "neither flag defined: --fail-under-lines is reported" "$ERRORS" "$LINES_MSG"
has "neither flag defined: --output is reported" "$ERRORS" "$OUTPUT_MSG"

run_guard pull_request false 80 "$(help_with "$OUTPUT_OPTION")"
expect_only "--output defined, --fail-under-lines not" "$LINES_MSG"

run_guard pull_request false 80 "$(help_with "$LINES_OPTION")"
expect_only "--fail-under-lines defined, --output not" "$OUTPUT_MSG"

# --- a flag the run does not need is not demanded -----------------------------------------

run_guard push true '' ""
expect_pass "a fat-mode push, with no help text at all"

run_guard push false '' ""
expect_pass "thin mode with the line gate off, on a push"

run_guard pull_request false '' "$(help_with "$OUTPUT_FILE_ONLY")"
expect_only "a pull request in thin mode with the line gate off" "$OUTPUT_MSG"

run_guard pull_request true 55 "$(help_with "$OUTPUT_OPTION")"
expect_pass "a fat-mode pull request with a line gate, which cargo llvm-cov enforces"

# --- an omni-dev with no `coverage` subcommand (below 0.29.0): `--help` itself fails ---------

run_guard pull_request false 80 "" "omni-dev 0.28.0" 2
eq "a failing --help: the step ends in its own errors, not clap's exit status" 1 "$STATUS"
eq "a failing --help: both flags are reported" 2 "$N_ERRORS"
has "a failing --help: --fail-under-lines is reported" "$ERRORS" "::error::omni-dev 0.28.0 $LINES_MSG"
has "a failing --help: --output is reported" "$ERRORS" "::error::omni-dev 0.28.0 $OUTPUT_MSG"
has "a failing --help: what omni-dev said stays in the log" "$OUT" "unrecognized subcommand 'coverage'"

run_guard push true '' "" "omni-dev 0.28.0" 2
expect_pass "a failing --help on a fat-mode push, which needs no flag"

# --- the real help of the releases either side of each floor -------------------------------
# 0.31.0 is the newest release without --output, 0.32.0 the floor; 0.44.0 the newest
# without --fail-under-lines, 0.45.0 the floor. The 0.28.0 case above stands for a release
# with no `coverage` subcommand: its --help is an error, not a text.

FIXTURES="$ROOT/tests/fixtures/omni-dev-help"
# real_help_case <version> <expect --output: yes|no> <expect --fail-under-lines: yes|no>
real_help_case() {
  local version=$1 want_output=$2 want_lines=$3 help
  help="$(cat "$FIXTURES/$version.txt")"
  # --output is needed on a pull request, --fail-under-lines in thin mode with the gate on:
  # one run per flag, so each answer is read on its own.
  run_guard pull_request true '' "$help" "omni-dev $version"
  if [ "$want_output" = yes ]; then
    expect_pass "real $version help: --output is found"
  else
    expect_only "real $version help: --output is missing" "$OUTPUT_MSG"
  fi
  run_guard push false 80 "$help" "omni-dev $version"
  if [ "$want_lines" = yes ]; then
    expect_pass "real $version help: --fail-under-lines is found"
  else
    expect_only "real $version help: --fail-under-lines is missing" "$LINES_MSG"
  fi
}

real_help_case 0.31.0 no no
real_help_case 0.32.0 yes no
real_help_case 0.44.0 yes no
real_help_case 0.45.0 yes yes

# --- how it asks -------------------------------------------------------------------------

run_guard pull_request false 80 "$(help_with "$OUTPUT_OPTION"$'\n\n'"$LINES_OPTION")"
eq "it captures the help once and asks for the version once" \
  $'coverage diff --help\n--version' "$CALLS"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
