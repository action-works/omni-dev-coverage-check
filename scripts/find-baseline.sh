#!/usr/bin/env bash
# Find the baseline coverage artifact for a pull request's merge-base.
#
# Used by the "Find baseline coverage" step. It decides WHICH run's artifact to
# download; the download itself stays with dawidd6/action-download-artifact, which is
# given the run id this script found.
#
# Inputs, from the environment so that action inputs never reach a shell as code:
#   BASELINE_WORKFLOW  workflow file (or id) the baseline artifact is published from
#   BASELINE_ARTIFACT  name of the baseline artifact
#   BASE_REF           the commit to start from: the merge-base, or the `base-ref` input
#   ANCESTOR_DEPTH     how many first-parent ancestors of it to try after it; 0 tries
#                      only BASE_REF (default 0)
#   GH_TOKEN           token for the Actions API; empty sends no Authorization header
#   GITHUB_REPOSITORY  owner/name
#   GITHUB_API_URL     API root (default https://api.github.com)
#   GITHUB_OUTPUT      file the outputs are appended to
#
# Outputs: `found` (true or false) and, when true, `run-id` (the run that holds the
# artifact), `sha` (the commit it was published for) and `distance` (0 for BASE_REF
# itself, N for its Nth first-parent ancestor).
#
# Exit status:
#   0  a baseline was found, or none was (a miss is not a failure, and neither is a
#      workflow the API does not know yet)
#   1  the API failed on the FIRST request, in a way that says nothing about the
#      baseline: a permission or an outage must not read as "there is none", or every
#      pull request would quietly pay for a rebuild
#   2  a usage error
#
# A failure further into the walk is a warned miss instead: the first request worked, so
# the credentials do, and what went wrong is transient (a rate limit, a server error).
# The baseline is optional, and the walk makes many more requests than one lookup did, so
# one blip on the eleventh must not fail a pull request. Transient statuses (no response,
# 429, 5xx) are retried first, three attempts in all, FIND_BASELINE_RETRY_DELAY seconds
# apart (default 2, times the attempt number).
#
# Candidates are BASE_REF and then its first-parent ancestors, nearest first. The first
# one that has a baseline wins. A commit has one if the workflow ran for it, with
# conclusion `success`, and that run holds a live (unexpired) artifact of that name. Each
# part is deliberate:
#   - Looking in EVERY successful run of the commit, not the newest. A `merge_group` run
#     and a `push` run share a head SHA, and the one that publishes is the `push` run; the
#     newest successful run can be the one that has no artifact.
#   - A run from a fork is skipped. A fork's pull request can carry any head SHA and
#     upload any artifact name, so trusting it would let it write the baseline. This is
#     dawidd6's `allow_forks: false`, which this replaces for the lookup.
#   - No `event` or `branch` filter. The artifact is the precise filter, and a filter
#     would break a caller that publishes from a schedule or a manual run.
#   - First-parent only. On `main` that is the line of merged pull requests, each of which
#     published a baseline; a second parent is a pull request's own branch, which did not.
#   - A 404 for the workflow is a warned miss and ends the walk: the API knows a workflow
#     only once its file is on the default branch, and every candidate would 404 alike.
#
# Each candidate costs at least one API request, plus one per successful run it has.

set -uo pipefail

fail() {
  echo "::error::$*"
  exit 1
}

workflow="${BASELINE_WORKFLOW:?BASELINE_WORKFLOW is not set}"
artifact="${BASELINE_ARTIFACT:?BASELINE_ARTIFACT is not set}"
start="${BASE_REF:?BASE_REF is not set}"
depth="${ANCESTOR_DEPTH:-0}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
out="${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
api_url="${GITHUB_API_URL:-https://api.github.com}"

case "$depth" in
  '' | *[!0-9]*)
    echo "::error::baseline-ancestor-depth must be a whole number of commits (0 or more), got '$depth'"
    exit 2
    ;;
esac
# Forced to base 10, so that a leading zero is not read as octal.
limit=$((10#$depth + 1))
retry_delay="${FIND_BASELINE_RETRY_DELAY:-2}"

API_BODY=""
API_STATUS=""

miss() { # <message>
  echo "::warning::$1"
  echo "found=false" >>"$out"
  exit 0
}

# Without these the requests are wrong, not absent: with no jq the names encode to nothing and
# the request goes to `.../workflows//runs`, which is a 404 that would read as "no such
# workflow". A runner without one still gets its comment, so this is a warned miss, and the
# warning names the cause.
for tool in git curl jq; do
  command -v "$tool" >/dev/null 2>&1 ||
    miss "$tool was not found on PATH, and the baseline lookup needs it. Continuing without a baseline."
done

# api <path and query>: GET it. The body is left in API_BODY and the HTTP status in
# API_STATUS (000 when there was no response). A transport failure is a status, not an
# exit, so the caller says what it means. Transient statuses are tried again.
api() {
  local response auth=() attempt=1
  if [ -n "${GH_TOKEN:-}" ]; then
    auth=(-H "Authorization: Bearer $GH_TOKEN")
  fi
  while :; do
    # `${auth[@]+...}`: an empty array is an unbound variable to bash 3.2 (macOS) under -u.
    response="$(curl -sS --max-time 60 ${auth[@]+"${auth[@]}"} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -w $'\n%{http_code}' "$api_url/$1")" || true
    API_STATUS="${response##*$'\n'}"
    API_BODY="${response%$'\n'*}"
    case "$API_STATUS" in
      [0-9][0-9][0-9]) ;;
      *) API_STATUS=000 ;;
    esac
    case "$API_STATUS" in
      000 | 429 | 5[0-9][0-9])
        [ "$attempt" -lt 3 ] || return 0
        sleep "$((attempt * retry_delay))"
        attempt=$((attempt + 1))
        ;;
      *) return 0 ;;
    esac
  done
}

# api_failed <what>: the API said something that is not an answer to the question. The first
# request failing is an error. Any later one is a miss: see the header.
api_failed() {
  local detail message
  message="$(jq -r '.message // empty' <<<"$API_BODY" 2>/dev/null || true)"
  if [ "$API_STATUS" = 000 ]; then
    detail="no response from $api_url"
  else
    detail="HTTP $API_STATUS${message:+: $message}"
  fi
  if [ "${distance:-0}" -gt 0 ]; then
    miss "Could not $1 ($detail), after the merge-base itself was looked up. Continuing without a baseline."
  fi
  if [ "$API_STATUS" = 000 ]; then
    fail "Could not $1: $detail. Re-run the job."
  fi
  fail "Could not $1 ($detail). If this is a permission, the token needs to be able to read workflow runs and their artifacts."
}

urlencode() {
  jq -rn --arg v "$1" '$v | @uri'
}

plural() { # <n> <word>
  if [ "$1" -eq 1 ]; then echo "$1 $2"; else echo "$1 $2s"; fi
}

workflow_enc="$(urlencode "$workflow")"
artifact_enc="$(urlencode "$artifact")"

if ! head_sha="$(git rev-parse --verify --quiet "${start}^{commit}")"; then
  miss "Could not resolve '$start' to a commit, so no baseline '$artifact' was looked up. Continuing without one."
fi

tried=0
while IFS= read -r sha; do
  distance=$tried
  tried=$((tried + 1))

  api "repos/$repo/actions/workflows/$workflow_enc/runs?head_sha=$sha&status=success&per_page=100"
  case "$API_STATUS" in
    200) ;;
    404)
      miss "Workflow '$workflow' was not found in $repo (HTTP 404), so there is no baseline '$artifact' to look up. The API knows a workflow only once its file is on the default branch. Continuing without a baseline."
      ;;
    *) api_failed "list the runs of workflow '$workflow'" ;;
  esac

  run_ids="$(jq -r --arg repo "$repo" \
    '.workflow_runs[]? | select(.conclusion == "success" and .head_repository.full_name == $repo) | .id' \
    <<<"$API_BODY")" || fail "The runs of workflow '$workflow' for ${sha:0:7} were not JSON"

  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue

    api "repos/$repo/actions/runs/$run_id/artifacts?name=$artifact_enc&per_page=100"
    case "$API_STATUS" in
      200) ;;
      404) continue ;; # the run was deleted after it was listed
      *) api_failed "list the artifacts of run $run_id" ;;
    esac
    live="$(jq --arg name "$artifact" \
      '[.artifacts[]? | select(.name == $name and (.expired | not))] | length' \
      <<<"$API_BODY")" || fail "The artifacts of run $run_id were not JSON"
    [ "$live" -gt 0 ] || continue

    {
      echo "found=true"
      echo "run-id=$run_id"
      echo "sha=$sha"
      echo "distance=$distance"
    } >>"$out"
    if [ "$distance" -eq 0 ]; then
      echo "Baseline '$artifact': run $run_id published it for ${sha:0:7}."
    else
      echo "::notice::No baseline '$artifact' for ${head_sha:0:7}; using the one for ${sha:0:7}, $(plural "$distance" commit) before it (run $run_id). The deltas also include whatever those commits changed."
    fi
    exit 0
  done <<<"$run_ids"
done < <(git rev-list --first-parent --max-count="$limit" "$head_sha")

if [ "$tried" -le 1 ]; then
  miss "No baseline '$artifact' was published by workflow '$workflow' for ${head_sha:0:7}. Continuing without one."
fi
miss "No baseline '$artifact' was published by workflow '$workflow' for ${head_sha:0:7} or the $(plural "$((tried - 1))" ancestor) checked before it. Continuing without one."
