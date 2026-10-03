#!/usr/bin/env bash
# Puts the sharded end-to-end fixture crate in the checkout, where the shard jobs
# measure it and the aggregation job diffs it.
#
# Usage: prepare-shard-crate.sh [--commit]   (run from the workspace root)
#   (none)    copy tests/fixtures/shard-crate/ to sharded-crate/
#   --commit  also commit it locally, on top of HEAD
#
# Why a copy, and why it is committed:
#   - The crate is copied to a directory of its own so the shards run cargo in it
#     and never at the root, and so no `Cargo.toml` appears in the repository.
#   - The patch gate passes when a diff adds no instrumented lines, so a pull
#     request that does not touch the crate would prove nothing about it. The
#     aggregation job commits the copy (never pushed): `merge-base..HEAD` then adds
#     every line of the crate whatever the pull request changes, while the merge-base
#     stays the real one, so the baseline lookup is not disturbed. Passing
#     `base-ref` instead would also fix the diff, but it keys the baseline lookup
#     too and would force a miss on every run.
#   - Every job copies to the same path under the same workspace root, so the
#     report paths the shards write line up with the diff the aggregation job builds.
#     The shards need no commit: it changes nothing about what they measure.
set -euo pipefail

commit=false
case "${1:-}" in
  '') ;;
  --commit) commit=true ;;
  *)
    echo "usage: prepare-shard-crate.sh [--commit]" >&2
    exit 2
    ;;
esac

src=tests/fixtures/shard-crate
dest=sharded-crate

if [ ! -d "$src" ]; then
  echo "::error::$src does not exist; run this from the workspace root"
  exit 1
fi
if [ -e "$dest" ]; then
  echo "::error::$dest already exists in the checkout; refusing to overwrite it"
  exit 1
fi

cp -R "$src" "$dest"

if [ "$commit" = true ]; then
  git add "$dest"
  git -c user.name=integration-test -c user.email=integration-test@invalid \
    commit -q -m 'test: add the shard fixture crate'
fi

echo "Prepared $dest (committed: $commit)"
