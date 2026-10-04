#!/usr/bin/env bash
# Fails unless every job the `ci-gate` job of integration.yml needs finished `success`.
#
# Usage: NEEDS='<toJSON(needs)>' ci-gate.sh
# Exit status: 0 if every needed job succeeded, 1 if any did not, 2 if there is nothing
# to judge (NEEDS unset, empty, not JSON, or not a non-empty object of jobs that each
# have a `result`). Every failure prints an `::error::` line.
#
# What backs the merge queue's one Integration check (#76). The ruleset requires
# `ci-gate` and not the twenty-odd Integration job names, which a matrix change would
# rename. `Failure messages` is skipped when a scenario job fails, and GitHub counts a
# skipped required check as passing, so requiring only that job would let a red pull
# request through. This is the job that is red instead: it runs `if: always()`, needs
# every other job in the file, and reads their results here.
#
# Anything but `success` is red, `skipped` and `cancelled` included. A skipped job is
# one whose own `needs` failed or were cancelled (no job in integration.yml has an
# `if:`), so it is never the first red thing, but passing it would be the hole this job
# exists to close. A job that is skipped on purpose later turns this red and the message
# names it, which is a louder way to be wrong than a quiet pass.
#
# An empty `needs` is refused, not passed: a gate over no jobs is how a deleted `needs:`
# would go unnoticed. `tests/merge-queue.test.sh` checks that `needs` still names every
# job of the file.
#
# The context arrives through the step's `env:`, never as an expression in the script
# (#39). Only jq is used besides builtins.
set -uo pipefail

needs="${NEEDS:-}"
if [ -z "$needs" ]; then
  echo "::error::ci-gate.sh needs the needs context in \$NEEDS (toJSON(needs)); got none"
  exit 2
fi

if ! command -v jq > /dev/null; then
  echo "::error::ci-gate.sh needs jq to read the needs context, and it is not on PATH"
  exit 2
fi

# `all(.[]; ...)` is true for an empty object, so the length is checked on its own.
if ! jq -e 'type == "object" and length > 0 and all(.[]; type == "object" and (.result | type == "string"))' \
  <<<"$needs" > /dev/null 2>&1; then
  # toJSON is pretty-printed: on one line, so the whole dump is in the annotation.
  echo "::error::ci-gate.sh did not get a non-empty object of jobs that each have a result; \$NEEDS is: $(printf '%s' "$needs" | tr '\n' ' ')"
  exit 2
fi

# The list is captured, not read from a process substitution: a jq that died there would
# leave the loop below with nothing to judge, and a loop over nothing counts no failure.
# @tsv escapes a tab or a newline in a name, so each job is one line and one workflow
# command.
if ! listing="$(jq -r 'to_entries[] | [.key, .value.result] | @tsv' <<<"$needs")" || [ -z "$listing" ]; then
  echo "::error::ci-gate.sh could not list the jobs in \$NEEDS, so it cannot say that they succeeded"
  exit 2
fi

total=0
bad=0
while IFS=$'\t' read -r job result; do
  total=$((total + 1))
  if [ "$result" = success ]; then
    echo "ok   - $job"
  else
    echo "::error::$job finished '$result', not 'success'"
    bad=$((bad + 1))
  fi
done <<<"$listing"

if [ "$bad" -ne 0 ]; then
  echo "::error::ci-gate: $bad of $total jobs did not succeed. A skipped job means one that it needs failed or was cancelled: look for that one above."
  exit 1
fi

echo "ok   - ci-gate: all $total jobs succeeded"
