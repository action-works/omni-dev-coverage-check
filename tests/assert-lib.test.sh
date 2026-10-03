#!/usr/bin/env bash
# Tests for tests/assert-lib.sh. Plain bash, no framework:
#   tests/assert-lib.test.sh
# Exits non-zero if any case fails.
#
# The library is what the e2e-sharded workflow's checks stand on, so what matters
# most here is that a check cannot pass when it should not: a missing number must
# fail a comparison either way, and a failed assert must set the status and show
# what the command printed.

# The `bash -c` snippets below are single-quoted on purpose: they expand in the
# child shell, with the library passed as $1.
# shellcheck disable=SC2016
set -uo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assert-lib.sh"
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

# pass <name> <command...>: passes when the command succeeds.
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

# In a child shell with the library sourced: lib <snippet>.
lib() {
  bash -c 'source "$1"; shift; eval "$1"' _ "$LIB" "$1"
}

# --- lt and ge: numbers ------------------------------------------------------

pass "lt: 1 < 2" lib 'lt 1 2'
fail "lt: 2 < 1" lib 'lt 2 1'
fail "lt: 2 < 2" lib 'lt 2 2'
pass "lt: 43.75 < 55" lib 'lt 43.75 55'
pass "lt: -1 < 0" lib 'lt -1 0'
pass "ge: 2 >= 2" lib 'ge 2 2'
pass "ge: 65.62 >= 55" lib 'ge 65.62 55'
fail "ge: 1 >= 2" lib 'ge 1 2'
fail "ge: 54.99 >= 55" lib 'ge 54.99 55'

# --- lt and ge: what is not a number -----------------------------------------
# awk would compare these as strings, and `null` > "55" as text, so ge would
# pass for a percentage that was never found. Both must fail, either way round.

fail "ge: null is not at least 55" lib 'ge null 55'
fail "lt: null is not below 55" lib 'lt null 55'
fail "ge: an empty string is not at least 55" lib 'ge "" 55'
fail "lt: an empty string is not below 55" lib 'lt "" 55'
fail "ge: 55 is not at least null" lib 'ge 55 null'
fail "lt: 55 is not below null" lib 'lt 55 null'
fail "ge: text is not at least 55" lib 'ge zzz 55'
fail "ge: a trailing garbage number" lib 'ge 70x 55'

# --- check -------------------------------------------------------------------

out="$(lib 'status=0; check "same" a a; echo "status=$status"')"
pass "check: equal values print ok" grep -qx 'ok   - same' <<<"$out"
pass "check: equal values leave the status" grep -qx 'status=0' <<<"$out"

out="$(lib 'status=0; check "differ" a b; echo "status=$status"')"
pass "check: a mismatch names expected and actual" grep -qx '::error::differ: expected a, got b' <<<"$out"
pass "check: a mismatch sets the status" grep -qx 'status=1' <<<"$out"

# --- assert ------------------------------------------------------------------

out="$(lib 'status=0; assert "fine" true; echo "status=$status"')"
pass "assert: success prints ok" grep -qx 'ok   - fine' <<<"$out"
pass "assert: success leaves the status" grep -qx 'status=0' <<<"$out"

out="$(lib 'status=0; assert "broken" false; echo "status=$status"')"
pass "assert: failure prints the label as an error" grep -qx '::error::broken' <<<"$out"
pass "assert: failure sets the status" grep -qx 'status=1' <<<"$out"

# What the command printed follows the error, indented, so a failed `jq -e` shows
# the value it saw.
out="$(lib 'status=0; assert "shows output" bash -c "echo seen-this; echo and-this >&2; exit 1"')"
pass "assert: failure shows stdout" grep -qx '       seen-this' <<<"$out"
pass "assert: failure shows stderr" grep -qx '       and-this' <<<"$out"

out="$(lib 'status=0; assert "silent" false')"
pass "assert: a command with no output adds no blank line" test "$(wc -l <<<"$out" | tr -d ' ')" = 1

pass "assert: runs a function from the library" lib 'status=0; assert "ge" ge 60 55; [ "$status" = 0 ]'
pass "assert: a failing library function sets the status" lib 'status=0; assert "ge" ge null 55 >/dev/null; [ "$status" = 1 ]'

# A failure must not stop the caller: the workflow reports every failure.
out="$(lib 'status=0; assert "first" false; assert "second" false; echo done')"
pass "assert: a second failure is still reported" grep -qx '::error::second' <<<"$out"
pass "assert: the caller keeps running" grep -qx 'done' <<<"$out"

# --- the fixture helpers -----------------------------------------------------

cat >"$WORK/fixture.rs" <<'EOF'
//! a comment
pub fn first() -> u32 {
    1
}

pub fn second() -> u32 {
    2
}
EOF
# first() declares line 2 and second() line 6.
mkdir -p "$WORK/shards"
printf 'SF:/ws/x.rs\nDA:2,1\nDA:6,0\nend_of_record' >"$WORK/shards/shard-1.lcov"
printf 'SF:/ws/x.rs\nDA:2,0\nDA:6,0\nend_of_record' >"$WORK/shards/shard-2.lcov"
printf 'SF:/ws/x.rs\nDA:2,1\nDA:6,1\nend_of_record' >"$WORK/shards/shard-3.lcov"

fixture_lib() { (cd "$WORK" && fixture="$WORK/fixture.rs" bash -c 'source "$1"; shift; eval "$1"' _ "$LIB" "$1"); }

pass "line_of: the declaration line" test "$(fixture_lib 'line_of first')" = 2
pass "line_of: a later function" test "$(fixture_lib 'line_of second')" = 6
pass "line_of: not fooled by a longer name" test "$(fixture_lib 'line_of firs')" = ""
pass "covers: a record with hits" fixture_lib 'covers shards/shard-1.lcov first'
fail "covers: a record without hits" fixture_lib 'covers shards/shard-2.lcov first'
fail "covers: a line only another function reaches" fixture_lib 'covers shards/shard-1.lcov second'
pass "covers: a combined report is covered if any record is" fixture_lib 'cat shards/shard-1.lcov > c.lcov; printf "\n" >> c.lcov; cat shards/shard-2.lcov >> c.lcov; covers c.lcov first'
pass "shards_covering: counts the shards that cover it" test "$(fixture_lib 'shards_covering first')" = 2
pass "shards_covering: counts the shards for another function" test "$(fixture_lib 'shards_covering second')" = 1
rm -f "$WORK/shards/shard-3.lcov"
pass "shards_covering: one of two" test "$(fixture_lib 'shards_covering first')" = 1

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
