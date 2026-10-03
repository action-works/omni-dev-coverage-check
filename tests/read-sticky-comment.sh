#!/usr/bin/env bash
# Reads back the sticky pull-request comment that carries a given header.
#
# Usage: read-sticky-comment.sh [--delete] <header> <outfile>
# Environment: GH_TOKEN, GITHUB_REPOSITORY, PR_NUMBER
#
# With --delete, every comment that carries the header is deleted after it has
# been read. The pr-paths workflow does this between scenarios that share a
# header: without it a scenario that stopped posting would still find the
# previous scenario's comment, which can be identical.
#
# Exit status:
#   0  exactly one comment carries the header; its body, without the marker, is
#      in <outfile>
#   3  none does, and nothing is written
#   4  more than one does: the sticky action is meant to update in place
#   other: the API call or the parse failed
#
# marocchino/sticky-pull-request-comment ends the body with
# `<!-- Sticky Pull Request Comment<header> -->`, which is how it finds its own
# comment again. Reading the comment back through the API is the only way to know
# it was posted. The caller can tell it is not an earlier push's comment, because
# the rendered body names the head commit.
set -euo pipefail

delete=false
if [ "${1:-}" = "--delete" ]; then
  delete=true
  shift
fi
header="${1:?usage: read-sticky-comment.sh [--delete] <header> <outfile>}"
out="${2:?usage: read-sticky-comment.sh [--delete] <header> <outfile>}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}" "${PR_NUMBER:?PR_NUMBER is not set}"

suffix=$'\n'"<!-- Sticky Pull Request Comment${header} -->"

# `--paginate` prints one JSON array per page; -s gathers them.
matches="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" |
  jq -s --arg suffix "$suffix" '[.[][] | select(.body | endswith($suffix))]')"
count="$(jq length <<<"$matches")"

if [ "$count" = 1 ]; then
  jq -j --arg suffix "$suffix" '.[0].body | rtrimstr($suffix)' <<<"$matches" >"$out"
fi

if [ "$delete" = true ]; then
  while IFS= read -r id; do
    gh api -X DELETE "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" >/dev/null
  done < <(jq -r '.[].id' <<<"$matches")
fi

case "$count" in
  0) exit 3 ;;
  1) ;;
  *)
    echo "::error::${count} comments carry the marker for header '${header}'; it should update in place"
    exit 4
    ;;
esac
