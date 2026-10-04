#!/usr/bin/env bash
# Tests for tests/test-lib.sh. Plain bash, no framework:
#   tests/test-lib.test.sh
# Exits non-zero if any case fails.
#
# Every tests/*.test.sh ends on `summary` and records its cases with these helpers, so
# what matters most is what they do when a case FAILS, which no other test exercises (they
# run green): a failed case must show its detail and make `summary` return non-zero, or
# every test file passes whatever it finds.
#
# The helpers cannot be judged by themselves. The first check below is plain bash and
# exits at once if `bad` and `summary` do not fail a run; after it, each case runs its
# snippet in a child shell and the verdict reads the child's status and output with
# `verdict`, not with the library's own eq / has.

# The snippets below are single-quoted on purpose: they expand in the child shell.
# shellcheck disable=SC2016
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run <snippet>: runs the snippet in a child shell that has the library sourced and
# `set -uo pipefail` as a test has it. Leaves its status in STATUS and its output (stdout
# and stderr together) in OUT.
run() {
  OUT="$(bash -c 'set -uo pipefail; LIB=$1; source "$LIB"; shift; eval "$1"' _ "$LIB" "$1" 2>&1)"
  STATUS=$?
}

run 'bad base; summary'
if [ "$STATUS" -ne 1 ] || [[ "$OUT" != *"FAIL - base"* ]] || [[ "$OUT" != *"0 passed, 1 failed"* ]]; then
  echo "FAIL - a failed case does not fail summary, so nothing below can be trusted: status $STATUS, output: $OUT"
  exit 1
fi

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$LIB"

# verdict <name> <status> <fragment>...: the last run exited with <status> and printed
# every fragment. A fragment that starts with ! must not appear in the output.
verdict() {
  local name=$1 want=$2 frag
  shift 2
  if [ "$STATUS" -ne "$want" ]; then
    bad "$name" "exit $STATUS, want $want; output: $OUT"
    return
  fi
  for frag in "$@"; do
    if [[ "$frag" == '!'* ]]; then
      if [[ "$OUT" == *"${frag#!}"* ]]; then
        bad "$name" "output holds '${frag#!}': $OUT"
        return
      fi
    elif [[ "$OUT" != *"$frag"* ]]; then
      bad "$name" "output lacks '$frag': $OUT"
      return
    fi
  done
  ok "$name"
}

# --- ok, bad, summary ----------------------------------------------------------

run 'ok first; ok second; summary'
verdict "summary: all cases pass, so it returns 0 and counts them" 0 \
  "ok   - first" "ok   - second" "2 passed, 0 failed"

run 'ok first; bad second "the detail"; summary'
verdict "summary: one failed case, so it returns non-zero and counts both kinds" 1 \
  "ok   - first" "FAIL - second" "1 passed, 1 failed"
verdict "bad: prints the detail after the name" 1 $'FAIL - second\n       the detail'

# The detail line is the one that starts with seven spaces.
run 'bad second; summary'
verdict "bad: with no detail it prints no detail line" 1 "FAIL - second" "!       "

run 'bad one; bad two; bad three; summary'
verdict "summary: counts every failed case" 1 "0 passed, 3 failed"

run 'bad early; ok later; summary'
verdict "summary: a failure before a pass is still a failure" 1 "FAIL - early" "ok   - later" "1 passed, 1 failed"

# A test file ends on `summary` with an EXIT trap set, which must not turn its status
# into the trap's. This is the shape of every test file.
for outcome in ok bad; do
  cat >"$WORK/$outcome.sh" <<EOF
set -uo pipefail
trap 'echo trap-ran' EXIT
source "$LIB"
ok one
$outcome two
summary
EOF
done
OUT="$(bash "$WORK/ok.sh" 2>&1)"
STATUS=$?
verdict "a script that ends on summary exits 0 when every case passed, trap or not" 0 \
  "2 passed, 0 failed" "trap-ran"
OUT="$(bash "$WORK/bad.sh" 2>&1)"
STATUS=$?
verdict "a script that ends on summary exits non-zero when one failed, trap or not" 1 \
  "1 passed, 1 failed" "trap-ran"

run 'before=$(set +o); source "$LIB"; after=$(set +o); [ "$before" = "$after" ] && echo options-unchanged'
verdict "sourcing the library changes no shell option" 0 "options-unchanged"

run 'summary'
verdict "summary: no case ran, so it returns non-zero and says why" 1 "0 passed, 0 failed" "no case ran"

run 'ok first; summary'
verdict "summary: it does not say no case ran when one did" 0 "!no case ran"

# --- eq --------------------------------------------------------------------------

run 'eq "same" a a; summary'
verdict "eq: equal values pass" 0 "ok   - same" "1 passed, 0 failed"

run 'eq "differ" expected actual; summary'
verdict "eq: different values fail and show both" 1 "FAIL - differ" "expected 'expected', got 'actual'"

run 'eq "both empty" "" ""; summary'
verdict "eq: two empty values are equal" 0 "ok   - both empty"

run 'eq "empty is not a value" "" x; summary'
verdict "eq: empty and not empty differ" 1 "FAIL - empty is not a value"

run 'eq "spaces" "a  b" "a b"; summary'
verdict "eq: whitespace counts" 1 "FAIL - spaces"

run 'eq "glob" "a*" "ab"; summary'
verdict "eq: compares text, not a pattern" 1 "FAIL - glob"

# --- has and lacks: a fixed string, not a pattern -----------------------------------

run 'has "found" "one two three" "two"; summary'
verdict "has: a fragment in the text passes" 0 "ok   - found"

run 'has "missing" "one two three" "four"; summary'
verdict "has: a fragment not in the text fails and shows both" 1 "FAIL - missing" "no 'four' in: one two three"

run 'has "star" "abc" "*"; summary'
verdict "has: * is a character, not a wildcard" 1 "FAIL - star"
run 'has "star present" "a*c" "*"; summary'
verdict "has: * is found where it is" 0 "ok   - star present"

run 'has "question" "abc" "a?c"; summary'
verdict "has: ? is a character, not a wildcard" 1 "FAIL - question"

run 'has "bracket" "abc" "[b]"; summary'
verdict "has: [b] is not a character class" 1 "FAIL - bracket"
run 'has "bracket present" "a[b]c" "[b]"; summary'
verdict "has: [b] is found where it is" 0 "ok   - bracket present"

run 'has "dash" "run --flag now" "--flag"; summary'
verdict "has: a fragment that starts with - is not an option" 0 "ok   - dash"

run 'text=$(printf "one\ntwo"); has "lines" "$text" "$text"; summary'
verdict "has: a fragment can span lines" 0 "ok   - lines"

run 'lacks "absent" "one two three" "four"; summary'
verdict "lacks: a fragment not in the text passes" 0 "ok   - absent"

run 'lacks "present" "one two three" "two"; summary'
verdict "lacks: a fragment in the text fails and shows both" 1 "FAIL - present" "unexpected 'two' in: one two three"

run 'lacks "star" "abc" "*"; summary'
verdict "lacks: * is a character, so text without one lacks it" 0 "ok   - star"
run 'lacks "star present" "a*c" "*"; summary'
verdict "lacks: * is found where it is" 1 "FAIL - star present"

run 'lacks "dash" "run now" "--flag"; summary'
verdict "lacks: a fragment that starts with - is not an option" 0 "ok   - dash"

# An empty fragment is in every text, so `has` would always pass and `lacks` always fail.
run 'has "empty" "abc" ""; summary'
verdict "has: an empty fragment fails and says it is empty" 1 "FAIL - empty" "the fragment is empty"
run 'FRAGMENT=; has "empty variable" "abc" "$FRAGMENT"; summary'
verdict "has: an empty variable as the fragment fails" 1 "FAIL - empty variable"
run 'lacks "empty" "abc" ""; summary'
verdict "lacks: an empty fragment fails and says it is empty" 1 "FAIL - empty" "the fragment is empty"
run 'has "empty text, a fragment" "" "x"; summary'
verdict "has: an empty text is not the problem, an empty fragment is" 1 "no 'x' in: " "!the fragment is empty"

# --- pass and fail: a command ------------------------------------------------------------

run 'pass "true" true; summary'
verdict "pass: a command that succeeds passes" 0 "ok   - true"

run 'pass "false" false; summary'
verdict "pass: a command that fails fails" 1 "FAIL - false" "!       "

run 'pass "arguments" test 1 -eq 1; summary'
verdict "pass: the command gets its arguments" 0 "ok   - arguments"

run 'pass "stdin" grep -q needle <<<"hay needle hay"; summary'
verdict "pass: the command gets the caller's stdin" 0 "ok   - stdin"

run 'fail "false" false; summary'
verdict "fail: a command that fails passes" 0 "ok   - false"

run 'fail "true" true; summary'
verdict "fail: a command that succeeds fails and says so" 1 "FAIL - true" "succeeded, but should have failed"

run 'fail "arguments" test 1 -eq 2; summary'
verdict "fail: the command gets its arguments" 0 "ok   - arguments"

# With no command, "$@" is empty and succeeds; a command that is not found "fails". Neither
# is a result, so neither passes.
run 'pass "no command"; summary'
verdict "pass: no command at all fails and says so" 1 "FAIL - no command" "no command to run: ''"
run 'COMMAND=; pass "empty command" $COMMAND; summary'
verdict "pass: an unquoted empty variable as the command fails" 1 "FAIL - empty command" "no command to run"
run 'pass "empty word" "" true; summary'
verdict "pass: an empty command word fails" 1 "FAIL - empty word" "no command to run"
run 'pass "not found" no-such-command-for-test-lib; summary'
verdict "pass: a command that is not found fails and names it" 1 "FAIL - not found" "no command to run: 'no-such-command-for-test-lib'"
run 'fail "no command"; summary'
verdict "fail: no command at all fails, and does not count as a command that failed" 1 \
  "FAIL - no command" "no command to run: ''"
run 'fail "not found" no-such-command-for-test-lib; summary'
verdict "fail: a command that is not found fails, and does not count as one that failed" 1 \
  "FAIL - not found" "no command to run: 'no-such-command-for-test-lib'"
run 'greet() { return 1; }; fail "a function" greet; pass "a builtin" test 1 -eq 1; summary'
verdict "pass and fail: a function and a builtin are commands" 0 "2 passed, 0 failed"

# --- the counters are shared by every helper ---------------------------------------------

run 'ok a; eq b 1 1; has c abc b; lacks d abc z; pass e true; fail f false; summary'
verdict "every helper counts in the same totals" 0 "6 passed, 0 failed"

run 'eq a 1 2; has b abc z; lacks c abc a; pass d false; fail e true; summary'
verdict "every helper counts a failure in the same totals" 1 "0 passed, 5 failed"

summary
