#!/usr/bin/env bash
# Prints the error messages that one job of the current workflow run logged.
#
# Usage: job-errors.sh <job name>
# Environment, retries and exit status: as job-log.sh, which reads the log.
#
# The integration workflow asserts what a failing scenario said, which a step
# cannot read from its own job and a composite action does not expose as an
# output. A later job can read the finished job's log through the API instead.
#
# Output: one line per `##[error]` line in the log, the timestamp and the marker
# removed. Those are the `::error::` commands the job ran, and the "Process
# completed with exit code" line of each failed step. Nothing else in the log is
# returned, because the rest is not what the job said: the log also echoes every
# step's script, and that echo holds the same message text (`echo "::error::…"`)
# whether or not the step ever ran it. The output is empty if the job logged no
# errors.
set -euo pipefail

name="${1:?usage: job-errors.sh <job name>}"
log="$(bash "$(dirname "${BASH_SOURCE[0]}")/job-log.sh" "$name")"

# A runner line is `<timestamp>Z <text>`; the first one also has a byte-order mark
# before the timestamp. Anchoring on the timestamp keeps a step's own output that
# merely contains the marker from counting.
printf '%s\n' "$log" | sed -n -E 's/^[^ ]*[0-9]Z ##\[error\]//p'
