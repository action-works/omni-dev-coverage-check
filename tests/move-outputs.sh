#!/usr/bin/env bash
# Moves one integration scenario's outputs into out/<id>/, so the next scenario
# starts from a clean workspace and cannot pass on this one's leftovers.
#
# Usage: move-outputs.sh <scenario-id>   (run from the workspace root)
#
# Covers what the action writes to fixed names in the workspace root (`baseline/`
# is the downloaded or recomputed baseline), and the marker files the fixture
# crate's tests leave there, and the merge log that tests/llvm-tool-shim.sh keeps
# (one line per profile merge the scenario ran). Each is moved only if it exists,
# because which of them a scenario produces is part of what it tests: a scenario
# that merged nothing has no log.
set -euo pipefail

id="${1:?usage: move-outputs.sh <scenario-id>}"

mkdir -p "out/$id"
for f in codecov.json coverage-summary.txt coverage.md coverage.json baseline \
  setup-ran.txt setup-test-ran.txt main-test-ran.txt llvm-profdata-merges.txt; do
  if [ -e "$f" ]; then
    mv "$f" "out/$id/"
  fi
done
