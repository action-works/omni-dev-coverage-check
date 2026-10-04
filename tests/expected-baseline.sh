#!/usr/bin/env bash
# What the baseline lookup should have found, according to the Actions API.
#
# Usage: expected-baseline.sh <workflow> <artifact> <start-sha> [depth]
# Environment: GH_TOKEN, GITHUB_REPOSITORY. Run it in the checkout, which needs full history.
#
# Prints one line:
#   hit <sha> <distance>  a baseline exists for that commit, `distance` first-parent
#                         commits before <start-sha>, and no nearer commit could still get one
#   miss                  none within `depth` commits, and nothing could still publish one
#   either                a run for a nearer commit (or for any, if none was found) has not
#                         finished, so it may have published between this call and the lookup
#                         and the lookup may have gone either way
#
# pr-paths.yml and e2e-sharded.yml compare this with what the action found, so both the hit
# and the miss path are tested whichever one a run takes. A baseline is looked up for a pull
# request's merge-base, and published only by a push to main, so the first pull request after
# a workflow lands cannot hit, and a recent merge-base may still be running.
#
# This is deliberately not scripts/find-baseline.sh again. It reads the same facts through
# another route (`gh`, no `status` filter, runs classified here), so a mistake in the lookup
# is not repeated in the check on it. It states the lookup's contract and nothing more:
#   - candidates are <start-sha> and then its first-parent ancestors, nearest first, up to
#     `depth` of them (default: the default of `baseline-ancestor-depth` in action.yml)
#   - a commit has a baseline if a successful run of the workflow in this repository for it
#     holds an unexpired artifact of that name; ANY such run counts, not the newest, because a
#     `merge_group` run that has none must not hide the `push` run that has one
set -euo pipefail

workflow="${1:?usage: expected-baseline.sh <workflow> <artifact> <start-sha> [depth]}"
artifact="${2:?usage: expected-baseline.sh <workflow> <artifact> <start-sha> [depth]}"
start="${3:?usage: expected-baseline.sh <workflow> <artifact> <start-sha> [depth]}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"

if [ -n "${4:-}" ]; then
  depth="$4"
else
  # The action's own default, so a change to it cannot leave this expecting the old one.
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  depth="$(awk '$0 == "  baseline-ancestor-depth:" { f = 1 } f && /^    default:/ { print $2; exit }' "$here/action.yml" | tr -d "'\"")"
  case "$depth" in
    '' | *[!0-9]*)
      echo "could not read the default of baseline-ancestor-depth from action.yml (got '$depth')" >&2
      exit 1
      ;;
  esac
fi

pending=false # a nearer commit has a run that has not finished
distance=0
while IFS= read -r sha; do
  runs="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?head_sha=$sha&per_page=100")"
  # `.head_repository.full_name`: a run from a fork is not a baseline.
  ours="$(jq -c --arg r "$GITHUB_REPOSITORY" '[.workflow_runs[] | select(.head_repository.full_name == $r)]' <<<"$runs")"

  for id in $(jq -r '.[] | select(.conclusion == "success") | .id' <<<"$ours"); do
    live="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$id/artifacts?per_page=100" |
      jq --arg n "$artifact" '[.artifacts[] | select(.name == $n and (.expired | not))] | length')"
    if [ "$live" -gt 0 ]; then
      if $pending; then echo either; else echo "hit $sha $distance"; fi
      exit 0
    fi
  done

  if jq -e 'any(.[]; .status != "completed")' <<<"$ours" >/dev/null; then
    pending=true
  fi
  distance=$((distance + 1))
done < <(git rev-list --first-parent --max-count="$((10#$depth + 1))" "$start")

if $pending; then echo either; else echo miss; fi
