#!/usr/bin/env bash
# shellcheck disable=SC2034 # `status` is the sourcing step's: set here, read there
# Assertion helpers for the e2e-sharded workflow's checking steps. Source it
# after `status=0`; a failed check or assert sets `status=1` in the caller, which
# ends its step with `exit "$status"` so every failure is reported, not just the
# first. tests/assert-lib.test.sh tests it.
#
# Why this is a file and not inlined in each step, as pr-paths.yml does: the
# workflow has three checking steps that need the same helpers, and what the
# numeric ones do with a missing value decides whether a gate's assertion can
# pass vacuously, so there is one copy to get right.
#
# The fixture helpers read the declaration lines of the fixture crate, because the
# FN records of an lcov carry hash-suffixed mangled names. `fixture` can be set
# before sourcing (the tests do) to point at another file.

fixture="${fixture:-tests/fixtures/shard-crate/src/lib.rs}"

check() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   - $1"
  else
    echo "::error::$1: expected $2, got $3"
    status=1
  fi
}

# Runs <command...> and says nothing while it succeeds. When it fails, the label is
# the error and what the command printed follows it: a `jq -e` that fails prints
# the `false` or `null` it saw, `cmp` says where two files differ. The first run
# of a check on a real runner is when its figures are first seen, and re-running
# with more logging is a slow way to learn them.
assert() { # <label> <command...>
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then
    echo "ok   - $label"
  else
    echo "::error::$label"
    if [ -n "$out" ]; then
      printf '       %s\n' "${out//$'\n'/$'\n'       }"
    fi
    status=1
  fi
}

# Numeric comparisons that succeed only for two numbers. awk compares a non-number
# as a string, so a percentage jq could not find (`null`, or an empty string) would
# quietly pass `ge` and the gate it stands for; here it fails both.
lt() { # <a> <b>: a < b
  awk -v a="$1" -v b="$2" 'function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ } BEGIN { exit !(num(a) && num(b) && a + 0 < b + 0) }'
}
ge() { # <a> <b>: a >= b
  awk -v a="$1" -v b="$2" 'function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ } BEGIN { exit !(num(a) && num(b) && a + 0 >= b + 0) }'
}

line_of() { # <function>: its declaration line in the fixture
  grep -n "pub fn $1(" "$fixture" | head -1 | cut -d: -f1
}

# Succeeds if any record of the function's declaration line has hits. A combined
# report holds one record per shard, so it is covered if any shard covered it.
covers() { # <lcov> <function>
  awk -F'[:,]' -v line="$(line_of "$2")" '$1 == "DA" && $2 == line && $3 > 0 { f = 1 } END { exit !f }' "$1"
}

shards_covering() { # <function>: how many of shards/shard-*.lcov cover it
  local shard n=0
  for shard in shards/shard-*.lcov; do
    if covers "$shard" "$1"; then n=$((n + 1)); fi
  done
  echo "$n"
}
