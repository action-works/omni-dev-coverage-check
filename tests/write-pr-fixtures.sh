#!/usr/bin/env bash
# Writes the fixtures the pr-paths workflow runs the action on, in the checkout.
#
# Usage: write-pr-fixtures.sh <baseline|head|extra>   (run from the workspace root)
#   baseline  what a push to main publishes
#   head      what a pull request is measured as
#   extra     a second file added to the patch, after `head` (see the end of this header)
#
# Two instrumented files, in two shard reports under shards/:
#   patch-fixture.txt  created and committed here, so the diff against the
#                      merge-base always adds exactly its 10 lines, whatever the
#                      pull request itself changes. Without it the patch gate
#                      would pass vacuously on a diff that touches no measured line.
#   LICENSE            an existing file no pull request is expected to touch (the
#                      head fixtures refuse to run if it does). It is the
#                      "indirect change": its coverage flips between baseline and
#                      head while its content does not.
#
# Union of the two shards (a line is covered if any shard covered it), which is
# what the combined report holds:
#                      baseline   head
#   patch-fixture.txt    5/10     8/10   each shard alone is under 60% in head
#   LICENSE (4 lines)    3/4      2/4    line 3 flips to uncovered
#   total                8/14     10/14  57.14% -> 71.43%
#
# The records carry `TN:<GITHUB_SHA>`, so a baseline downloaded later says which
# commit it was published for. Each shard ends without a newline after its final
# `end_of_record`, as `cargo llvm-cov` writes it.
#
# `extra` adds to what `head` wrote, for the scenarios that show `ignore-filename-regex`
# reaching the patch gate: patch-extra.txt, committed locally like patch-fixture.txt,
# with 10 added lines none of them covered, in a third shard (shards/shard-3.lcov). The
# patch is then 8 of 20 lines (40%), and 8 of 10 (80%) once the filter drops the new file.
# It is a separate step so the scenarios that do not want it are written without it.
#
# Editing the patterns changes what the workflow's assertions compare against
# only through the fixtures themselves: they recompute the expected totals from
# the downloaded baseline and the head report instead of hard-coding them.
set -euo pipefail

kind="${1:?usage: write-pr-fixtures.sh <baseline|head|extra>}"
ws="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
tn="${GITHUB_SHA:?GITHUB_SHA is not set}"

# 10 lines to be "added" by the pull request under test, none covered by the one shard that
# names them. Committed locally and never pushed, so the merge-base is unchanged.
if [ "$kind" = extra ]; then
  if [ ! -e patch-fixture.txt ] || [ ! -d shards ]; then
    echo "::error::run 'write-pr-fixtures.sh head' first: extra adds to its fixtures"
    exit 1
  fi
  if [ -e patch-extra.txt ] || [ -e shards/shard-3.lcov ]; then
    echo "::error::patch-extra.txt or shards/shard-3.lcov already exists in the checkout; refusing to overwrite it"
    exit 1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "extra $i"
  done >patch-extra.txt
  git add patch-extra.txt
  git -c user.name=integration-test -c user.email=integration-test@invalid \
    commit -q -m 'test: add a second file with known added lines'
  {
    printf 'TN:%s\nSF:%s/patch-extra.txt\n' "$tn" "$ws"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      printf 'DA:%d,0\n' "$i"
    done
    printf 'end_of_record'
  } >shards/shard-3.lcov
  echo "Wrote the extra fixtures:"
  ls -l shards
  exit 0
fi

if [ -e patch-fixture.txt ] || [ -e shards ]; then
  echo "::error::patch-fixture.txt or shards/ already exists in the checkout; refusing to overwrite it"
  exit 1
fi
if [ "$(wc -l <LICENSE)" -lt 4 ]; then
  echo "::error::LICENSE has fewer than 4 lines; the fixture instruments its first 4"
  exit 1
fi

# A shard's patch-fixture.txt hits and LICENSE hits, by line number.
case "$kind" in
  baseline)
    patch1=(1 1 1 0 0 0 0 0 0 0)
    patch2=(0 0 1 1 1 0 0 0 0 0)
    license1=(1 1 0 0)
    license2=(0 1 1 0)
    ;;
  head)
    patch1=(1 1 1 1 1 0 0 0 0 0)
    patch2=(0 0 0 0 1 1 1 1 0 0)
    license1=(1 1 0 0)
    license2=(0 1 0 0)
    ;;
  *)
    echo "usage: write-pr-fixtures.sh <baseline|head|extra>" >&2
    exit 2
    ;;
esac

record() { # <file> <hits>...
  local file="$1" line=1 hits
  shift
  printf 'TN:%s\nSF:%s/%s\n' "$tn" "$ws" "$file"
  for hits in "$@"; do
    printf 'DA:%d,%d\n' "$line" "$hits"
    line=$((line + 1))
  done
  printf 'end_of_record\n'
}

# A pull request that edits LICENSE would add its lines to the patch and stop it
# being an indirect change, and the assertions would fail without saying why.
if [ "$kind" = head ]; then
  merge_base="$(git merge-base origin/main HEAD)"
  if ! git diff --quiet "$merge_base" HEAD -- LICENSE; then
    echo "::error::this pull request changes LICENSE, which the head fixtures instrument as a file no diff touches. Pick another untouched file in tests/write-pr-fixtures.sh."
    exit 1
  fi
fi

mkdir shards out
# Command substitution drops the trailing newline, which is the point.
shard1="$(
  record patch-fixture.txt "${patch1[@]}"
  record LICENSE "${license1[@]}"
)"
shard2="$(
  record patch-fixture.txt "${patch2[@]}"
  record LICENSE "${license2[@]}"
)"
printf '%s' "$shard1" >shards/shard-1.lcov
printf '%s' "$shard2" >shards/shard-2.lcov

# Ten lines to be "added" by the pull request under test. Committed locally and
# never pushed, so the merge-base is unchanged and the diff gains these lines.
for i in 1 2 3 4 5 6 7 8 9 10; do
  echo "line $i"
done >patch-fixture.txt
git add patch-fixture.txt
git -c user.name=integration-test -c user.email=integration-test@invalid \
  commit -q -m 'test: add a file with known added lines'

echo "Wrote the $kind fixtures:"
ls -l shards
