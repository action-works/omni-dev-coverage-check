#!/usr/bin/env bash
# Tests for the "Check omni-dev supports the flags this run uses" step of action.yml.
# Plain bash, no framework:
#   tests/guard-step.test.sh
# Exits non-zero if any case fails.
#
# The step asks omni-dev whether it accepts each flag the run needs, by calling
# `omni-dev coverage diff <flag> x --help` and reading clap's answer: `unexpected argument
# '<flag>' found` (or `unrecognized subcommand`) means missing, anything else means present.
# The integration legs run that against real releases, so they cannot reach what no release
# does yet: a flag omni-dev accepts but hides from its help, a help line that begins with a
# flag's name, clap's colour codes, a message nobody has seen. This runs the step against a
# stub `omni-dev` whose answers each case chooses, and asserts which `::error::` lines the
# step prints, how it exits and what it asked. The step's script is read out of action.yml
# itself, so renaming the step or moving its `run:` block fails here, by name, rather than
# leaving a test of a copy.
#
# The stub answers the probe the way clap does (the layouts and messages are the real ones),
# and it also prints a plain `coverage diff --help`, which the step must never ask for: a
# case whose help text lies (it hides a flag omni-dev accepts, or names one it lacks) would
# fool a step that went back to reading it. tests/fixtures/omni-dev-probe/ holds what the real
# releases either side of each floor answered to the probe, replayed below so the wording the
# step relies on is held to what omni-dev prints. Refresh one, with that release's omni-dev on
# PATH, with
#   out="$(omni-dev coverage diff --output x --help 2>&1)"; printf 'exit=%s\n%s\n' "$?" "$out" \
#     >tests/fixtures/omni-dev-probe/<version>/output.txt
# and likewise for fail-under-lines. Every failing case has a control that differs only in
# what the stub accepts.
#
# What this does not reach: the step's `if:`, which decides whether it runs at all. The
# script asks about a flag whatever the event only when the run needs it, so the "flag not
# needed" cases show it does not demand or ask about a flag the run does not use, not that it
# is skipped. The `output-flag` job of integration.yml runs on every event and covers the
# `if:`.

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

# --- the stub omni-dev -----------------------------------------------------------------
# It answers three calls. `--version` prints FAKE_VERSION. A plain `coverage diff --help`
# prints FAKE_HELP (the step must not ask; see above). `coverage diff <flag> <value> --help`
# is the probe, answered the way clap does, by the environment a case sets:
#   FAKE_ACCEPTS      the flags `coverage diff` knows, space-separated (default: none)
#   FAKE_ACCEPT_MODE  what a known flag says to the dummy value: `invalid` (the default:
#                     exit 2, `invalid value 'x'`), `ok` (exit 0, prints the help, as for a
#                     free-form value) or `novalue` (a flag that takes none: exit 2, and
#                     the unexpected argument is `x`, not the flag)
#   FAKE_NO_COVERAGE  1: no `coverage` subcommand (omni-dev below 0.29.0)
#   FAKE_PROBE_FAIL   a message that is neither of clap's, printed with exit 1
#   FAKE_REPLAY_DIR   a directory of what a real release answered (tests/fixtures/
#                     omni-dev-probe/<version>): replay `<flag minus dashes>.txt`
# An unknown flag gets clap's `tip:` for the first known one, and with CLICOLOR_FORCE=1 and
# no NO_COLOR the message is coloured the way clap does it, which splits the flag's name.
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/omni-dev" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$OMNI_DEV_LOG"
if [ "${CLICOLOR_FORCE:-}" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ERR=$'\e[1m\e[31merror:\e[0m'
  HI=$'\e[33m'
  LO=$'\e[0m'
else
  ERR='error:'
  HI=''
  LO=''
fi
case "$*" in
  --version)
    echo "$FAKE_VERSION"
    exit 0
    ;;
  'coverage diff --help')
    printf '%s\n' "${FAKE_HELP:-}"
    exit 0
    ;;
esac
if [ "$#" -ne 5 ] || [ "$1 $2" != 'coverage diff' ] || [ "$5" != --help ]; then
  echo "stub omni-dev: unexpected arguments: $*" >&2
  exit 99
fi
flag=$3
value=$4
if [ -n "${FAKE_REPLAY_DIR:-}" ]; then
  file="$FAKE_REPLAY_DIR/${flag#--}.txt"
  status="$(head -n1 "$file")"
  tail -n +2 "$file" >&2
  exit "${status#exit=}"
fi
if [ -n "${FAKE_PROBE_FAIL:-}" ]; then
  echo "$FAKE_PROBE_FAIL" >&2
  exit 1
fi
if [ "${FAKE_NO_COVERAGE:-}" = 1 ]; then
  {
    echo "$ERR unrecognized subcommand '${HI}coverage${LO}'"
    echo
    echo "Usage: omni-dev [OPTIONS] <COMMAND>"
  } >&2
  exit 2
fi
case " ${FAKE_ACCEPTS:-} " in
  *" $flag "*)
    case "${FAKE_ACCEPT_MODE:-invalid}" in
      ok)
        printf '%s\n' "${FAKE_HELP:-}"
        exit 0
        ;;
      novalue)
        echo "$ERR unexpected argument '$value' found" >&2
        exit 2
        ;;
      *)
        echo "$ERR invalid value '$value' for '$flag <VALUE>'" >&2
        exit 2
        ;;
    esac
    ;;
esac
{
  echo "$ERR unexpected argument '${HI}${flag}${LO}' found"
  if [ -n "${FAKE_ACCEPTS:-}" ]; then
    echo
    echo "  tip: a similar argument exists: '${FAKE_ACCEPTS%% *}'"
  fi
  echo
  echo "Usage: omni-dev coverage diff [OPTIONS] --report <PATH>"
} >&2
exit 2
EOF
chmod +x "$BIN/omni-dev"

# --- help texts, which the step must not read ------------------------------------------------

# A plain help that lists both flags, one that lists neither (what omni-dev prints once it has
# hidden a flag it still accepts), and one whose description lines begin with a flag's name
# (`--output is the format of the diff`) without defining it.
HELP_LISTING=$'      --report <PATH>\n          Head coverage report.\n\n  -o, --output <OUTPUT>\n          Output format.\n\n      --fail-under-lines <PCT>\n          Exit non-zero when the line total is below this percentage.'
HELP_HIDING=$'      --report <PATH>\n          Head coverage report.\n\n      --fail-under-patch <PCT>\n          Exit non-zero when patch coverage is below this percentage.'
HELP_PROSE=$'      --report <PATH>\n          Head coverage report.\n\n      --report-format <FORMAT>\n          The format of a report. Not to be confused with what\n          --output is the format of the diff, and what\n          --fail-under-lines is the gate on the total.'

# --- running the step ----------------------------------------------------------------

# run_guard <event> <run-coverage> <fail-under-lines> [NAME=value ...]: runs the step as the
# runner would, with the inputs it reads in its environment, and the NAME=value pairs in the
# stub's (see above; FAKE_VERSION and CLICOLOR_FORCE too). Sets STATUS (the step's exit
# status), OUT (its output), ERRORS (its `::error::` lines), N_ERRORS and CALLS (what it
# asked omni-dev, one call per line).
run_guard() {
  local event=$1 run_coverage=$2 gate=$3 dir
  shift 3
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  : >"$dir/omni-dev.log"
  OUT="$(
    env PATH="$BIN:$PATH" OMNI_DEV_LOG="$dir/omni-dev.log" \
      FAKE_VERSION='omni-dev 0.45.0 (2de88c54 2026-10-03)' \
      EVENT_NAME="$event" RUN_COVERAGE="$run_coverage" FAIL_UNDER_LINES="$gate" "$@" \
      bash --noprofile --norc -eo pipefail -c "$GUARD" 2>&1
  )"
  STATUS=$?
  ERRORS="$(grep '^::error::' <<<"$OUT" || true)"
  N_ERRORS="$(grep -c '^::error::' <<<"$OUT" || true)"
  CALLS="$(cat "$dir/omni-dev.log")"
}

OUTPUT_MSG="has no 'coverage diff --output'"
LINES_MSG="has no 'coverage diff --fail-under-lines'"
VERSION_CALL='--version'
OUTPUT_PROBE='coverage diff --output x --help'
LINES_PROBE='coverage diff --fail-under-lines x --help'

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

run_guard pull_request true '' FAKE_ACCEPTS=--output FAKE_HELP="$HELP_LISTING"
expect_pass "--output accepted, rejecting the dummy value"
eq "--output accepted: it asked once, for that flag, and never read the plain help" \
  "$VERSION_CALL"$'\n'"$OUTPUT_PROBE" "$CALLS"

run_guard pull_request true '' FAKE_ACCEPTS=--output FAKE_ACCEPT_MODE=ok FAKE_HELP="$HELP_LISTING"
expect_pass "--output accepted with exit 0"

run_guard pull_request true '' FAKE_ACCEPTS=--output FAKE_ACCEPT_MODE=novalue FAKE_HELP="$HELP_LISTING"
expect_pass "--output accepted but taking no value (clap names the dummy value, not the flag)"

# The case this step was reworked for: omni-dev hides a flag it still accepts. Its help no
# longer lists --output, which is what a step reading the help would call missing.
run_guard pull_request true '' FAKE_ACCEPTS=--output FAKE_HELP="$HELP_HIDING"
expect_pass "--output accepted but hidden from the help"

# And the reverse: help lines that begin with the flag's name, on an omni-dev without it.
# The control is the same help text on an omni-dev that has the flag.
run_guard pull_request true '' FAKE_HELP="$HELP_PROSE"
expect_only "--output named in help prose, not accepted" "$OUTPUT_MSG"
run_guard pull_request true '' FAKE_ACCEPTS=--output FAKE_HELP="$HELP_PROSE"
expect_pass "--output named in help prose, accepted"

run_guard pull_request true '' FAKE_ACCEPTS=--output-file
expect_only "only --output-file accepted" "$OUTPUT_MSG"

run_guard pull_request true '' FAKE_ACCEPTS=--fail-under-lines
expect_only "a different flag accepted, --output not" "$OUTPUT_MSG"

# What the log shows for a missing flag: the line omni-dev said, then the error.
run_guard pull_request true '' FAKE_ACCEPTS=--output-file
has "a missing --output shows what omni-dev said" "$OUT" "omni-dev said: error: unexpected argument '--output' found"

# The message the user reads: the omni-dev found (its number, commit and date, as
# `omni-dev --version` prints them), the floor and the way out.
run_guard pull_request true '' FAKE_VERSION="omni-dev 0.31.0 (0a1b2c3d 2025-01-02)"
has "the --output error names the omni-dev found" "$ERRORS" "::error::omni-dev 0.31.0 (0a1b2c3d 2025-01-02) has no"
has "the --output error names the floor" "$ERRORS" "0.32.0 or later"
has "the --output error says how to fix it" "$ERRORS" "set 'version' to 0.32.0 or later, or to 'latest'"

# --- clap's colour -------------------------------------------------------------------------
# A caller that sets CLICOLOR_FORCE gets `'<escape>--output<escape>'` out of omni-dev, which
# no match on the flag's name finds. The step sets NO_COLOR for the probe, which wins over it.

run_guard pull_request true '' CLICOLOR_FORCE=1
expect_only "a missing --output under forced colour" "$OUTPUT_MSG"
run_guard pull_request true '' CLICOLOR_FORCE=1 FAKE_ACCEPTS=--output
expect_pass "an accepted --output under forced colour"
run_guard pull_request false 80 CLICOLOR_FORCE=1 FAKE_NO_COVERAGE=1
eq "no coverage subcommand under forced colour: both reported" 2 "$N_ERRORS"

# --- it fails open --------------------------------------------------------------------------
# A probe that fails in a way nobody has seen (a rewording, an omni-dev that crashes) counts as
# the flag being there: the later step then gets clap's own error, as before this step
# existed. Pinned so that changing it is a decision. The version step has already proved the
# binary runs.

run_guard pull_request false 80 FAKE_PROBE_FAIL='error: something nobody has seen'
expect_pass "a probe that fails with an unknown message"

# --- --fail-under-lines: thin mode with the line gate on ----------------------------------

run_guard push false 80 FAKE_ACCEPTS=--fail-under-lines FAKE_HELP="$HELP_LISTING"
expect_pass "--fail-under-lines accepted, rejecting the dummy value"
eq "--fail-under-lines accepted: it asked once, for that flag, and never read the plain help" \
  "$VERSION_CALL"$'\n'"$LINES_PROBE" "$CALLS"

run_guard push false 80 FAKE_ACCEPTS=--fail-under-lines FAKE_ACCEPT_MODE=ok FAKE_HELP="$HELP_LISTING"
expect_pass "--fail-under-lines accepted with exit 0"

run_guard push false 80 FAKE_ACCEPTS=--fail-under-lines FAKE_HELP="$HELP_HIDING"
expect_pass "--fail-under-lines accepted but hidden from the help"

run_guard push false 80 FAKE_HELP="$HELP_PROSE"
expect_only "--fail-under-lines named in help prose, not accepted" "$LINES_MSG"
run_guard push false 80 FAKE_ACCEPTS=--fail-under-lines FAKE_HELP="$HELP_PROSE"
expect_pass "--fail-under-lines named in help prose, accepted"

run_guard push false 80 FAKE_ACCEPTS=--fail-under-lines-per-file
expect_only "only --fail-under-lines-per-file accepted" "$LINES_MSG"

run_guard push false 80 FAKE_ACCEPTS=--output
expect_only "a different flag accepted, --fail-under-lines not" "$LINES_MSG"

run_guard push false 80 FAKE_VERSION="omni-dev 0.44.0 (0a1b2c3d 2025-01-02)"
has "the --fail-under-lines error names the omni-dev found" "$ERRORS" "::error::omni-dev 0.44.0 (0a1b2c3d 2025-01-02) has no"
has "the --fail-under-lines error says how to fix it" "$ERRORS" "or set 'fail-under-lines' to an empty string to run thin mode without a line gate"

# --- both, and each independent of the other ----------------------------------------------

run_guard pull_request false 80 "FAKE_ACCEPTS=--output --fail-under-lines"
expect_pass "both flags accepted"
eq "both flags: it asked once for each, the line gate first" \
  "$VERSION_CALL"$'\n'"$LINES_PROBE"$'\n'"$OUTPUT_PROBE" "$CALLS"

run_guard pull_request false 80 "FAKE_ACCEPTS=--output-file --fail-under-lines-per-file"
eq "neither flag accepted: the step fails" 1 "$STATUS"
eq "neither flag accepted: it reports both, not just the first" 2 "$N_ERRORS"
has "neither flag accepted: --fail-under-lines is reported" "$ERRORS" "$LINES_MSG"
has "neither flag accepted: --output is reported" "$ERRORS" "$OUTPUT_MSG"

run_guard pull_request false 80 FAKE_ACCEPTS=--output
expect_only "--output accepted, --fail-under-lines not" "$LINES_MSG"

run_guard pull_request false 80 FAKE_ACCEPTS=--fail-under-lines
expect_only "--fail-under-lines accepted, --output not" "$OUTPUT_MSG"

# --- a flag the run does not need is not asked about --------------------------------------

run_guard push true ''
expect_pass "a fat-mode push"
eq "a fat-mode push: it asked about no flag" "$VERSION_CALL" "$CALLS"

run_guard push false ''
expect_pass "thin mode with the line gate off, on a push"
eq "thin mode with the line gate off: it asked about no flag" "$VERSION_CALL" "$CALLS"

run_guard pull_request false '' FAKE_ACCEPTS=--fail-under-lines
expect_only "a pull request in thin mode with the line gate off" "$OUTPUT_MSG"
eq "a pull request in thin mode with the line gate off: it asked only about --output" \
  "$VERSION_CALL"$'\n'"$OUTPUT_PROBE" "$CALLS"

run_guard pull_request true 55 FAKE_ACCEPTS=--output
expect_pass "a fat-mode pull request with a line gate, which cargo llvm-cov enforces"
eq "a fat-mode pull request with a line gate: it asked only about --output" \
  "$VERSION_CALL"$'\n'"$OUTPUT_PROBE" "$CALLS"

# --- an omni-dev with no `coverage` subcommand (below 0.29.0): the probe itself fails -------

run_guard pull_request false 80 FAKE_NO_COVERAGE=1 FAKE_VERSION="omni-dev 0.28.0"
eq "no coverage subcommand: the step ends in its own errors, not clap's exit status" 1 "$STATUS"
eq "no coverage subcommand: both flags are reported" 2 "$N_ERRORS"
has "no coverage subcommand: --fail-under-lines is reported" "$ERRORS" "::error::omni-dev 0.28.0 $LINES_MSG"
has "no coverage subcommand: --output is reported" "$ERRORS" "::error::omni-dev 0.28.0 $OUTPUT_MSG"
has "no coverage subcommand: what omni-dev said stays in the log" "$OUT" "omni-dev said: error: unrecognized subcommand 'coverage'"

run_guard push true '' FAKE_NO_COVERAGE=1 FAKE_VERSION="omni-dev 0.28.0"
expect_pass "no coverage subcommand on a fat-mode push, which needs no flag"

# --- what the real releases said to the probe -----------------------------------------------
# tests/fixtures/omni-dev-probe/ holds the answers of the releases either side of each floor:
# 0.31.0 is the newest release without --output, 0.32.0 the floor; 0.44.0 the newest without
# --fail-under-lines, 0.45.0 the floor; 0.28.0 the newest with no `coverage` subcommand at all.
# The wording the step matches is the wording they print.

FIXTURES="$ROOT/tests/fixtures/omni-dev-probe"
# real_case <version> <expect --output: yes|no> <expect --fail-under-lines: yes|no>
real_case() {
  local version=$1 want_output=$2 want_lines=$3
  # --output is needed on a pull request, --fail-under-lines in thin mode with the gate on:
  # one run per flag, so each answer is read on its own.
  run_guard pull_request true '' FAKE_REPLAY_DIR="$FIXTURES/$version" FAKE_VERSION="omni-dev $version"
  if [ "$want_output" = yes ]; then
    expect_pass "real $version: --output is found"
  else
    expect_only "real $version: --output is missing" "$OUTPUT_MSG"
  fi
  run_guard push false 80 FAKE_REPLAY_DIR="$FIXTURES/$version" FAKE_VERSION="omni-dev $version"
  if [ "$want_lines" = yes ]; then
    expect_pass "real $version: --fail-under-lines is found"
  else
    expect_only "real $version: --fail-under-lines is missing" "$LINES_MSG"
  fi
}

real_case 0.28.0 no no
real_case 0.31.0 no no
real_case 0.32.0 yes no
real_case 0.44.0 yes no
real_case 0.45.0 yes yes

# Each fixture is what it says it is, so a replay that never reached the step's match would
# not pass for the wrong reason: the missing flags say `unexpected argument`, and the present
# ones do not.
has "the 0.31.0 fixture is clap's unexpected-argument message" "$(cat "$FIXTURES/0.31.0/output.txt")" "error: unexpected argument '--output' found"
has "the 0.28.0 fixture is clap's unrecognized-subcommand message" "$(cat "$FIXTURES/0.28.0/output.txt")" "error: unrecognized subcommand 'coverage'"
lacks "the 0.45.0 fixture does not say the flag is unexpected" "$(cat "$FIXTURES/0.45.0/fail-under-lines.txt")" "unexpected argument"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
