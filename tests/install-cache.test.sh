#!/usr/bin/env bash
# Tests for tests/install-cache.sh. Plain bash, no framework:
#   tests/install-cache.test.sh
# Exits non-zero if any case fails.
#
# The script decides which events install the omni-dev binary for real (the cache
# prefix) and what a job that restored it from the cache must do (the check), so the
# cases that matter most are the ones where a wrong answer is silent: a prefix that does
# not change when the install code or the run does (the cache hits and nothing says so),
# an empty hash (a constant prefix), and a cache hit on a run that cannot have saved one.
#
# The script runs under `env -i`: on a runner the tests themselves run with
# GITHUB_EVENT_NAME and GITHUB_RUN_ID set, and a case must set what it is about.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/install-cache.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

# hashFiles gives 64 hex characters. A and B differ in their first 16.
HASH_A=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
HASH_B=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

# run <event> <run id> <attempt> <hash> <script arguments...>
# Sets STATUS, OUT (stdout) and ERR (stderr) of the script.
run() {
  local event=$1 id=$2 attempt=$3 hash=$4
  shift 4
  OUT="$(env -i PATH="$PATH" GITHUB_EVENT_NAME="$event" GITHUB_RUN_ID="$id" \
    GITHUB_RUN_ATTEMPT="$attempt" INSTALL_CODE_HASH="$hash" bash "$SCRIPT" "$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(<"$WORK/err")"
}

# prefix_of <event> <run id> <attempt> <hash>: the prefix, or fails the case if the script did.
prefix_of() {
  run "$1" "$2" "$3" "$4" prefix
  printf '%s' "$OUT"
}

# --- prefix: the events that install on a change to the install code -----------------

for event in pull_request push; do
  run "$event" 100 1 "$HASH_A" prefix
  eq "$event: the prefix is the first 16 characters of the hash of the install code" "install-0123456789abcdef-" "$OUT"
  eq "$event: it exits 0" 0 "$STATUS"
  eq "$event: it says nothing else on stderr" "" "$ERR"
done

# A change to the install code changes the hash, and so the key, so the cache misses.
changed="$(prefix_of pull_request 100 1 "$HASH_B")"
unchanged="$(prefix_of pull_request 100 1 "$HASH_A")"
pass "pull_request: a different hash gives a different prefix" test "$changed" != "$unchanged"
eq "pull_request: ... which is the next hash's 16 characters" "install-fedcba9876543210-" "$changed"

# Runs on unchanged code reuse the entry: the run does not change the prefix, or each
# push to a pull request would write an entry nothing restores.
eq "pull_request: another run of the same code gets the same prefix" "$unchanged" "$(prefix_of pull_request 999 3 "$HASH_A")"
eq "push: the same code gives the pull request's prefix" "$unchanged" "$(prefix_of push 100 1 "$HASH_A")"

# --- prefix: the events that install every time --------------------------------------

for event in schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" prefix
  eq "$event: the prefix is made of the run and the attempt" "run-100-1-" "$OUT"
  eq "$event: it exits 0" 0 "$STATUS"
  eq "$event: it says nothing else on stderr" "" "$ERR"
done

base="$(prefix_of schedule 100 1 "$HASH_A")"
pass "schedule: another run gets another prefix" test "$(prefix_of schedule 101 1 "$HASH_A")" != "$base"
pass "schedule: a re-run (another attempt) gets another prefix" test "$(prefix_of schedule 100 2 "$HASH_A")" != "$base"
eq "schedule: the install code does not matter, only the run does" "$base" "$(prefix_of schedule 100 1 "$HASH_B")"
eq "schedule: no hash is needed" "$base" "$(prefix_of schedule 100 1 "")"
pass "the two kinds of prefix cannot be the same key" test "$base" != "$unchanged"

# --- prefix: what it refuses ---------------------------------------------------------

# An empty hash is what hashFiles gives when its globs match nothing. A prefix that
# ignored it would be the same on every run and the cache would never miss.
run pull_request 100 1 "" prefix
eq "pull_request with no hash: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says which variable is wrong" "$ERR" "::error::install-cache.sh: INSTALL_CODE_HASH"
has "  and says what the globs may have matched" "$ERR" "do the globs match nothing?"

run push 100 1 "not-a-hash" prefix
eq "push with a hash that is not hex: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run push 100 1 "abc123" prefix
eq "push with a hash under 16 characters: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run schedule "" 1 "$HASH_A" prefix
eq "schedule with no run id: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says what it needs" "$ERR" "GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT"

run workflow_dispatch 100 "" "$HASH_A" prefix
eq "workflow_dispatch with no attempt: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run schedule "12 34" 1 "$HASH_A" prefix
eq "schedule with a run id that is not a number: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run "" 100 1 "$HASH_A" prefix
eq "no event: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says the event is unknown" "$ERR" "GITHUB_EVENT_NAME is not set"

# --- check: the install ran ----------------------------------------------------------

for event in pull_request push schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" check false
  eq "$event, no cache hit: exits 0" 0 "$STATUS"
  has "  and says the install ran" "$OUT" "omni-dev was installed in this job"
  eq "  and says nothing on stderr" "" "$ERR"
done

# --- check: a cache hit --------------------------------------------------------------

# On unchanged install code the entry is the one an earlier run saved: correct, and the
# log says the download and the extraction did not run here.
for event in pull_request push; do
  run "$event" 100 1 "$HASH_A" check true
  eq "$event, cache hit: exits 0" 0 "$STATUS"
  has "  and says it came from the cache" "$OUT" "omni-dev came from the cache, not from an install"
  has "  and says the install did not run" "$OUT" "did not run in this job"
  lacks "  and does not say it was installed" "$OUT" "omni-dev was installed in this job"
done

# Their prefix is unique to the run, so there was nothing to restore: the prefix did not
# reach the action, which is exactly what the check is there to catch.
for event in schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" check true
  eq "$event, cache hit: exits 1" 1 "$STATUS"
  has "  and names the event" "$ERR" "on a $event run"
  has "  and says the prefix did not reach the action" "$ERR" "the prefix did not reach the action"
  has "  and is an error annotation" "$ERR" "::error::install-cache.sh:"
  eq "  and prints nothing on stdout" "" "$OUT"
done

run "" 100 1 "$HASH_A" check true
eq "cache hit with no event: exits 1" 1 "$STATUS"
has "  and says the event is unknown" "$ERR" "GITHUB_EVENT_NAME is not set"

# --- check: no usable answer ---------------------------------------------------------

# A scenario that failed exposes no outputs, so the value arrives empty. Treating that as
# a hit or as an install would pass whatever the action did.
run pull_request 100 1 "$HASH_A" check ""
eq "no value: exits 2, as a usage error" 2 "$STATUS"
has "  and says what it needed" "$ERR" "omni-dev-cache-hit output"
eq "  and prints nothing on stdout" "" "$OUT"

run pull_request 100 1 "$HASH_A" check
eq "no argument: exits 2" 2 "$STATUS"

run pull_request 100 1 "$HASH_A" check maybe
eq "a value that is neither: exits 1" 1 "$STATUS"
has "  and names it" "$ERR" "'maybe'"

run pull_request 100 1 "$HASH_A" check True
eq "True is not true: exits 1" 1 "$STATUS"

# --- usage ---------------------------------------------------------------------------

run pull_request 100 1 "$HASH_A"
eq "no subcommand: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" restore
eq "an unknown subcommand: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" prefix extra
eq "prefix with an argument: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" check true false
eq "check with two arguments: exits 2" 2 "$STATUS"

summary
