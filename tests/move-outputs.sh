#!/usr/bin/env bash
# Moves one integration scenario's outputs into out/<id>/, so the next scenario
# starts from a clean workspace and cannot pass on this one's leftovers.
#
# Usage: move-outputs.sh <scenario-id>   (run from the workspace root)
#
# Covers what the action writes to fixed names in the workspace root (`baseline/`
# is the downloaded or recomputed baseline), and the marker files the fixture
# crate's tests leave there. Each is moved only if it exists, because which of
# them a scenario produces is part of what it tests.
set -euo pipefail

id="${1:?usage: move-outputs.sh <scenario-id>}"

mkdir -p "out/$id"
for f in codecov.json coverage-summary.txt coverage.md coverage.json baseline \
  setup-ran.txt setup-test-ran.txt main-test-ran.txt; do
  if [ -e "$f" ]; then
    mv "$f" "out/$id/"
  fi
done
