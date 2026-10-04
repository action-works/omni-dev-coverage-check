#!/usr/bin/env bash
# Prints the jobs of the current workflow run as one JSON array, for a step that has to
# read them all and not one by name (#89).
#
# Usage: run-jobs.sh
# Environment: GH_TOKEN (with `actions: read`), GITHUB_REPOSITORY, GITHUB_RUN_ID
#   RUN_JOBS_MIN      optional: the fewest jobs the run is known to have. A shorter list is
#                     looked at again, as one that is short in any other way is. Unset means
#                     no minimum; SET BUT EMPTY is refused, since an empty value is how a
#                     caller whose count failed to compute arrives, and reading it as "no
#                     bound" would drop the bound without a word (default: unset)
#   JOB_LOG_ATTEMPTS  how many times to try (default 6); the same variable as job-log.sh
#   JOB_LOG_DELAY     seconds between tries (default 10)
#
# Output: on stdout, one line, `[{"id":N,"name":"...","status":"...","conclusion":"..."}, ...]`
# (`conclusion` is null for a job that is still running), and nothing else; every message
# goes to stderr. `filter=latest` is the newest attempt of each job, so a re-run does not
# read a stale one.
#
# Why it looks again (#69, #89). tests/job-log.sh lists the jobs to find one by name, and on
# re-runs of a workflow the list has come back without jobs that were there, a different few
# each time and complete again later, and a 502 now and then. A step that reads EVERY job has
# no name to miss, so a short list reads fewer jobs and still passes. What this treats as a
# list that has to be looked at again:
#   - a failed call (a 502, a missing permission);
#   - a body that is not JSON, or JSON with no `jobs` (a rate-limit answer is one);
#   - no job at all (the job that is reading is itself in the run);
#   - a number of jobs that is not the API's own: the answer carries `total_count`, and a
#     list that holds fewer than that is cut short (one that holds more is wrong in some other
#     way, and is looked at again too). Only the first page's count is read, and a response
#     without one is not held to it;
#   - fewer jobs than RUN_JOBS_MIN, the one thing a caller can know without the list: a job
#     that `needs` N others runs after them, so the run has at least N + 1 jobs with itself.
#
# What it does not do: prove the list complete. RUN_JOBS_MIN is a lower bound, and a matrix
# job is several jobs for each entry it counts as one, so a list short by fewer jobs than the
# matrices add clears it. `total_count` only shows a list that disagrees with the API's own
# count, which was not observed: #69's short lists were not examined for it. A list that is
# short and consistent is read as complete. This is a retry for the failures that were seen,
# and a bound for the grossest short list, not a check.
#
# Exit status: 0 and the list. Otherwise 1, with `::error::` on stderr naming the run, the
# attempts and the LAST attempt's reason (the earlier ones are in the lines above it); 2
# for a RUN_JOBS_MIN that is not a whole number. It costs what any failure that will not
# clear costs (a token without `actions: read`, no `gh` or `jq`): all the attempts, 50
# seconds with the defaults.
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}" "${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}"
attempts="${JOB_LOG_ATTEMPTS:-6}"
delay="${JOB_LOG_DELAY:-10}"
min="${RUN_JOBS_MIN-0}"
case "$min" in
  '' | *[!0-9]*)
    echo "::error::RUN_JOBS_MIN must be a whole number, got '${min}'" >&2
    exit 2
    ;;
esac

err="$(mktemp)"
trap 'rm -f -- "$err"' EXIT

problem=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  problem=""
  # `--paginate` prints one JSON object per page; -s gathers them.
  if pages="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?filter=latest&per_page=100" 2>"$err")"; then
    if list="$(jq -s -c '
        if length > 0 and all(.[]; type == "object" and (.jobs | type) == "array") then
          {total: .[0].total_count, jobs: [.[].jobs[] | {id, name, status, conclusion}]}
        else
          error("the answer holds no list of jobs")
        end' <<<"$pages" 2>"$err")"; then
      count="$(jq '.jobs | length' <<<"$list")"
      total="$(jq -r '.total // "none"' <<<"$list")"
      if [ "$count" -eq 0 ]; then
        problem="the list holds no job, and this job is in the run"
      elif [ "$total" != none ] && [ "$total" != "$count" ]; then
        problem="the list holds ${count} jobs and the API counts ${total}"
      elif [ "$count" -lt "$min" ]; then
        problem="the list holds ${count} jobs and the run has at least ${min}"
      else
        jq -c '.jobs' <<<"$list"
        exit 0
      fi
    else
      problem="$(<"$err")"
    fi
  else
    problem="$(<"$err")"
  fi
  problem="${problem:-no message}"
  # One line: a workflow command is read a line at a time, and only the first line of a
  # multi-line ::error:: would be the annotation.
  problem="${problem//$'\n'/ }"
  echo "the jobs of run ${GITHUB_RUN_ID} could not be listed (attempt ${attempt} of ${attempts}): ${problem}" >&2
  [ "$attempt" -eq "$attempts" ] || sleep "$delay"
done
echo "::error::could not list the jobs of run ${GITHUB_RUN_ID} after ${attempts} attempts: ${problem}" >&2
exit 1
