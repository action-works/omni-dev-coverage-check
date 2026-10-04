#!/usr/bin/env bash
# Fails unless the omni-dev on PATH is the version a job pinned.
#
# Usage: assert-omni-dev-version.sh <version>
# Exit status: 0 if it is, 1 if it is not (or cannot report a version), 2 for a
# missing or empty <version>. Every failure prints an `::error::` line.
#
# What backs the "one omni-dev version per job" rule in the integration workflows:
# `actions/cache` saves in a post step, so a second version installed over
# ~/.cargo/bin/omni-dev poisons the first version's key, and this is where that
# shows. The workflows call it as `bash tests/assert-omni-dev-version.sh "$VERSION"
# || status=1`; a bare call would end the step under Actions' `bash -e` before the
# step's other checks had reported.
#
# The version line is `omni-dev 0.45.0 (b5445b9 2026-10-03)` (a `, dirty` can follow
# the date in a local build; 0.28.0 to 0.32.0, clap's `#[command(version)]`, print just
# `omni-dev 0.28.0`): a commit and date may follow the number, so it cannot be
# compared whole. It must start with `omni-dev <version>`, and the number must
# then end, at a space or at the end of the line. A substring match (`grep -F`)
# lets a pin that is a prefix or a suffix of another release's number pass for
# it: `0.4.1` for `0.4.10`, `1.2.3` for `11.2.3`. Every character of the pin is
# literal here, so a dot is a dot and a `+` is a plus; a regex would need each
# one escaped.
#
# `omni-dev --version` is captured before it is matched, as the guard in
# action.yml does, so a binary that fails reports itself instead of a grep on an
# empty pipe. Its stderr is left alone for the same reason.
#
# Only builtins are used, so the tests can run it with a PATH that holds nothing
# but a stub `omni-dev`.
set -uo pipefail

version="${1:-}"
if [ -z "$version" ]; then
  # An empty pin is how a step that failed (and so exposed no `version` output)
  # arrives here. Matching it against everything would pass whatever is on PATH.
  echo "::error::assert-omni-dev-version.sh needs the version to expect; got none. Usage: assert-omni-dev-version.sh <version>"
  exit 2
fi

if ! command -v omni-dev > /dev/null; then
  echo "::error::omni-dev is not on PATH (expected $version)"
  exit 1
fi

found="$(omni-dev --version)"
status=$?
if [ "$status" -ne 0 ]; then
  echo "::error::omni-dev --version exited $status (expected $version): ${found:-no output}"
  exit 1
fi

if [[ $found != "omni-dev $version" && $found != "omni-dev $version "* ]]; then
  echo "::error::omni-dev on PATH is not $version ($found); a poisoned cache?"
  exit 1
fi

echo "ok   - omni-dev on PATH is $version ($found)"
