#!/usr/bin/env bash
# The helpers every tests/*.test.sh stands on. Plain bash, no framework. Source it
# after `set -uo pipefail` and end the test with `summary`:
#
#   # shellcheck source-path=SCRIPTDIR
#   # shellcheck source=test-lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
#   ...
#   summary
#
# Each helper records one case, prints `ok   - <name>` or `FAIL - <name>` (with the
# detail on the line after), and counts it in $passed / $failed. `summary` prints the
# totals and returns non-zero if any case failed, so as the test's last command it is
# the test's exit status. tests/test-lib.test.sh tests it: ten files end on it, so a
# `summary` that returned 0 would pass them all.
#
# It sets no shell option, so the test's own `set` stays in force. A case recorded in a
# subshell (`( ... )`, a pipeline) is not counted: the counters live in the caller.
#
# Not here, on purpose: tests/assert-lib.sh is a different helper set (the e2e
# workflow's `check <label> <expected> <actual>`), and sourcing both would make `check`
# mean two things. That is why the command checker below is `pass`.

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

# lacks <name> <text> <fragment>: the text does not contain the fragment.
lacks() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected '$3' in: $2"; fi
}

# pass <name> <command...>: passes when the command succeeds. The command keeps the
# caller's stdin, so a here-string on the call reaches it.
pass() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# fail <name> <command...>: passes when the command fails.
fail() {
  local name=$1
  shift
  if "$@"; then bad "$name" "succeeded, but should have failed"; else ok "$name"; fi
}

# summary: the totals, and a status that is non-zero if any case failed.
summary() {
  echo
  echo "$passed passed, $failed failed"
  [ "$failed" -eq 0 ]
}
