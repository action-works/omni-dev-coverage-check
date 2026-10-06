#!/usr/bin/env bash
# Fails unless the patchcov on PATH is the version a job pinned.
#
# Usage: assert-patchcov-version.sh <version>
# Exit status: 0 if it is, 1 if it is not (or cannot report a version), 2 for a
# missing or empty <version>. Every failure prints an `::error::` line.
#
# What backs the "one patchcov version per job" rule in the integration workflows:
# `actions/cache` saves in a post step, so a second version installed over
# ~/.cargo/bin/patchcov poisons the first version's key, and this is where that
# shows. The workflows call it as `bash tests/assert-patchcov-version.sh "$VERSION"
# || status=1`; a bare call would end the step under Actions' `bash -e` before the
# step's other checks had reported.
#
# Released patchcov prints `patchcov 0.1.1`. Also accept optional build metadata
# after a space for development binaries. Match the whole version literally:
# a substring or regex would accept the wrong version. Capture status before
# matching so a binary that fails to start cannot pass.
#
# Only builtins are used, so the tests can run it with a PATH that holds nothing
# but a stub `patchcov`.
set -uo pipefail

version="${1:-}"
if [ -z "$version" ]; then
  # An empty pin is how a step that failed (and so exposed no `version` output)
  # arrives here. Matching it against everything would pass whatever is on PATH.
  echo "::error::assert-patchcov-version.sh needs the version to expect; got none. Usage: assert-patchcov-version.sh <version>"
  exit 2
fi

if ! command -v patchcov > /dev/null; then
  echo "::error::patchcov is not on PATH (expected $version)"
  exit 1
fi

found="$(patchcov --version)"
status=$?
if [ "$status" -ne 0 ]; then
  echo "::error::patchcov --version exited $status (expected $version): ${found:-no output}"
  exit 1
fi

if [[ $found != "patchcov $version" && $found != "patchcov $version "* ]]; then
  echo "::error::patchcov on PATH is not $version ($found); a poisoned cache?"
  exit 1
fi

echo "ok   - patchcov on PATH is $version ($found)"
