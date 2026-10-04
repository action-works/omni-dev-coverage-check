#!/usr/bin/env bash
# Prints the warnings that one job of the current workflow run logged.
#
# Usage: job-warnings.sh <job name>
# Environment, retries and exit status: as job-log.sh, which reads the log.
#
# A scenario that exists for a warning (#61: the redirect fallback of "Resolve omni-dev
# version" logs one when the API refuses the token) cannot be asserted from its own job, and
# a composite action exposes no output for it. A later job reads the finished job's log
# through the API instead, as tests/job-errors.sh does for errors.
#
# Output: one line per `##[warning]` line in the log, the timestamp and the marker removed.
# Those are the `::warning::` commands the job ran and the runner's own notices (the
# `Node.js 20 is deprecated` one is in every log), and this does not tell them apart: it
# only reads, and the caller says which warning it means. Nothing else in the log is
# returned: the log also echoes every step's script, which holds the same message text
# (`echo "::warning::..."`) whether or not the step ran it, and a program's own
# `warning: ...` line, which tests/job-deprecations.sh reads, is not a runner warning. The
# output is empty if the job logged none. A warning is not a failure: this never turns a
# job red for logging one, and a caller that expects none says so itself.
set -euo pipefail

name="${1:?usage: job-warnings.sh <job name>}"
log="$(bash "$(dirname "${BASH_SOURCE[0]}")/job-log.sh" "$name")"

# A runner line is `<timestamp>Z <text>`; the first one also has a byte-order mark before
# the timestamp. Anchoring on the timestamp keeps a step's own output that merely contains
# the marker from counting.
printf '%s\n' "$log" | sed -n -E 's/^[^ ]*[0-9]Z ##\[warning\]//p'
