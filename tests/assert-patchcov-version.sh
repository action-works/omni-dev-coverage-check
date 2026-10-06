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
# The version line is `patchcov 0.1.1 (b5445b9 2026-10-03)` (a `, dirty` can follow
# the date in a local build; 0.28.0 to 0.32.0, clap's `#[command(version)]`, print just
# `patchcov 0.28.0`): a commit and date may follow the number, so it cannot be
# compared whole. It must start with `patchcov <version>`, and the number must
# then end, at a space or at the end of the line. A substring match (`grep -F`)
# lets a pin that is a prefix or a suffix of another release's number pass for
# it: `0.4.1` for `0.4.10`, `1.2.3` for `11.2.3`. Every character of the pin is
# literal here, so a dot is a dot and a `+` is a plus; a regex would need each
# one escaped.
#
# `patchcov --version` is captured before it is matched, as the guard in
# action.yml does, so a binary that fails reports itself instead of a grep on an
# empty pipe. Its stderr is left alone for the same reason.
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
