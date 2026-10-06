#!/usr/bin/env bash
# Prints the line coverage of an lcov report as a percentage with two decimals.
#
# Usage: lcov-percent.sh <lcov>
# Exit status: 0 with the percentage on stdout, 2 for a wrong number of arguments.
#
# A file's repeated records (one per shard, in a combined report) are unioned the
# way `patchcov diff` does: a line is covered if any record hit it. The
# pr-paths workflow recomputes a total from the report itself, so what it asserts
# about patchcov's figure does not depend on the numbers the fixtures hold.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: lcov-percent.sh <lcov>" >&2
  exit 2
}

awk -F'[:,]' '
  /^SF:/ { sf = substr($0, 4) }
  $1 == "DA" { k = sf SUBSEP $2; if (!(k in h) || $3 + 0 > h[k]) h[k] = $3 + 0 }
  END { for (k in h) { t++; if (h[k] > 0) c++ } printf "%.2f", t ? 100 * c / t : 0 }' "$1"
