#!/usr/bin/env bash
# Prints the log of one job of the current workflow run, carriage returns removed.
#
# Usage: job-log.sh <job name>
# Environment: GH_TOKEN (with `actions: read`), GITHUB_REPOSITORY, GITHUB_RUN_ID
#   JOB_LOG_ATTEMPTS  how many times to try reading the log (default 6)
#   JOB_LOG_DELAY     seconds between tries (default 10)
#
# What a step cannot read from its own job, and a composite action does not expose
# as an output, a later job can read from the finished job's log through the API.
# This script does the reading; job-errors.sh and job-deprecations.sh pick out the
# lines they are about. Every line is a runner line, `<timestamp>Z <text>` (the
# first one also has a byte-order mark before the timestamp), and the log also echoes
# every step's script, so a caller must say which lines it means and not search the
# whole text for words that a script may hold.
#
# Exit status: 0 when the job was found and its log read. Otherwise non-zero, with a
# message on stderr saying which of these it was: the run has no job with exactly
# that name (or more than one), the log could not be read, or an API call failed.
# The status itself does not say, because `gh` uses some of the small numbers for
# its own errors.
#
# `filter=latest` is the newest attempt of each job, so a re-run does not read a
# stale one. The log is read from a job that has already finished. The API has
# served it at once on every run so far, a couple of seconds after that job ended;
# the retries are insurance against that not holding, not a known need. A
# permanent failure (a missing permission, say) is retried too, and the last
# attempt's own error is what the final message carries.
set -euo pipefail

name="${1:?usage: job-log.sh <job name>}"
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
# sequences unless told to, and a runner log is full of colour codes. The log is
# captured and filtered by the caller and never reaches a terminal. An older gh has
# neither the refusal nor the flag.
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

printf '%s\n' "$log" | tr -d '\r'
