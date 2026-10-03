#!/usr/bin/env bash
# Prints the error messages that one job of the current workflow run logged.
#
# Usage: job-errors.sh <job name>
# Environment: GH_TOKEN (with `actions: read`), GITHUB_REPOSITORY, GITHUB_RUN_ID
#   JOB_LOG_ATTEMPTS  how many times to try reading the log (default 6)
#   JOB_LOG_DELAY     seconds between tries (default 10)
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
# whether or not the step ever ran it.
#
# Exit status: 0 when the job was found and its log read (the output is empty if
# it logged no errors). Otherwise non-zero, with a message on stderr saying which
# of these it was: the run has no job with exactly that name (or more than one),
# the log could not be read, or an API call failed. The status itself does not
# say, because `gh` uses some of the small numbers for its own errors.
#
# `filter=latest` is the newest attempt of each job, so a re-run does not read a
# stale one. The log is read from a job that has already finished, but whether the
# API serves it at that moment is not guaranteed, hence the retries.
set -euo pipefail

name="${1:?usage: job-errors.sh <job name>}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}" "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
attempts="${JOB_LOG_ATTEMPTS:-6}"
delay="${JOB_LOG_DELAY:-10}"

# `--paginate` prints one JSON object per page; -s gathers them.
jobs="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?filter=latest&per_page=100")"
ids="$(jq -s -c --arg name "$name" '[.[].jobs[] | select(.name == $name) | .id]' <<<"$jobs")"
count="$(jq length <<<"$ids")"
if [ "$count" != 1 ]; then
  echo "::error::run ${GITHUB_RUN_ID} has ${count} jobs named '${name}', not one" >&2
  exit 1
fi
id="$(jq -r '.[0]' <<<"$ids")"

# gh 2.97 and later refuse to print a response that holds terminal escape
# sequences unless told to, and a runner log is full of colour codes (the same
# bytes this script's sed leaves alone). The log is captured and filtered here and
# never reaches a terminal. An older gh has neither the refusal nor the flag.
# The help is captured first, not piped: `grep -q` can exit before gh has finished
# writing, and with pipefail the pipeline then fails and the flag is skipped.
log_flags=()
help="$(gh api --help 2>&1)"
if grep -q -- '--allow-escape-sequences' <<<"$help"; then
  log_flags+=(--allow-escape-sequences)
fi

err="$(mktemp)"
trap 'rm -f -- "$err"' EXIT
fetched=false
last_error=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if log="$(gh api ${log_flags[@]+"${log_flags[@]}"} "repos/${GITHUB_REPOSITORY}/actions/jobs/${id}/logs" 2>"$err")"; then
    fetched=true
    break
  fi
  last_error="$(<"$err")"
  echo "the log of job ${id} is not readable yet (attempt ${attempt} of ${attempts}): ${last_error}" >&2
  [ "$attempt" -eq "$attempts" ] || sleep "$delay"
done
if [ "$fetched" != true ]; then
  echo "::error::could not read the log of job '${name}' (${id}) after ${attempts} attempts: ${last_error}" >&2
  exit 1
fi

# A runner line is `<timestamp>Z <text>`; the first one also has a byte-order mark
# before the timestamp. Anchoring on the timestamp keeps a step's own output that
# merely contains the marker from counting.
printf '%s\n' "$log" | tr -d '\r' | sed -n -E 's/^[^ ]*[0-9]Z ##\[error\]//p'
