#!/usr/bin/env bash
# Tests for tests/prepare-shard-crate.sh. Plain bash, no framework:
#   tests/prepare-shard-crate.test.sh
# Exits non-zero if any case fails.
#
# The script is what keeps the e2e-sharded workflow's patch gate from passing
# vacuously, so the property that matters is the last group: whatever a pull
# request changes, `merge-base..HEAD` adds every line of the crate.

# The `bash -c` snippets below are single-quoted on purpose: they expand in the
# child shell.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/prepare-shard-crate.sh"

# Hermetic: the script's commit must not depend on, or be altered by, the
# caller's git configuration (a signing key, a hook path).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# repo: a fresh repository on `main`, holding the real fixture crate, with
# origin/main pointing at its one commit. Prints its path.
repo() {
  local dir
  dir="$(mktemp -d "$WORK/repo.XXXXXX")"
  (
    cd "$dir" || exit 1
    git init -q -b main .
    git config user.name t
    git config user.email t@invalid
    mkdir -p tests/fixtures
    cp -R "$ROOT/tests/fixtures/shard-crate" tests/fixtures/
    git add -A
    git commit -q -m base
    git update-ref refs/remotes/origin/main HEAD
  )
  echo "$dir"
}

# --- copy only ---------------------------------------------------------------

d="$(repo)"
head_before="$(git -C "$d" rev-parse HEAD)"
out="$(cd "$d" && bash "$SCRIPT" 2>&1)"
pass "copies Cargo.toml" test -f "$d/sharded-crate/Cargo.toml"
pass "copies src/lib.rs" test -f "$d/sharded-crate/src/lib.rs"
pass "the copy is the fixture" diff -r "$ROOT/tests/fixtures/shard-crate" "$d/sharded-crate"
pass "does not commit" test "$(git -C "$d" rev-parse HEAD)" = "$head_before"
pass "leaves the copy untracked" test "$(git -C "$d" status --porcelain)" = "?? sharded-crate/"
pass "says it did not commit" grep -qF 'committed: false' <<<"$out"

# --- --commit ----------------------------------------------------------------

d="$(repo)"
head_before="$(git -C "$d" rev-parse HEAD)"
(cd "$d" && bash "$SCRIPT" --commit >/dev/null 2>&1)
pass "--commit: HEAD moves on by exactly one commit" test "$(git -C "$d" rev-list --count "$head_before"..HEAD)" = 1
pass "--commit: the working tree is clean" test -z "$(git -C "$d" status --porcelain)"
pass "--commit: the commit holds the crate's files" \
  test "$(git -C "$d" diff --name-only "$head_before" HEAD | tr '\n' ' ')" = "sharded-crate/Cargo.toml sharded-crate/src/lib.rs "
pass "--commit: the commit is made without any git configuration" \
  test "$(git -C "$d" log -1 --format=%an)" = integration-test

# --- refusals ----------------------------------------------------------------

d="$(repo)"
(cd "$d" && bash "$SCRIPT" >/dev/null 2>&1)
out="$(cd "$d" && bash "$SCRIPT" 2>&1)"
rc=$?
pass "refuses to overwrite an existing sharded-crate/" test "$rc" = 1
pass "names the directory it refused" grep -qF 'sharded-crate already exists' <<<"$out"

out="$(cd "$WORK" && bash "$SCRIPT" 2>&1)"
rc=$?
pass "fails when run outside the workspace root" test "$rc" = 1
pass "says where the fixture should be" grep -qF 'tests/fixtures/shard-crate does not exist' <<<"$out"

(cd "$d" && bash "$SCRIPT" --nope >/dev/null 2>&1)
pass "an unknown argument exits 2" test "$?" = 2

# --- a file `git add` would skip ---------------------------------------------
# An ignore rule that matches part of the crate: the commit would be short of
# lines the shards measured. It must fail, name the file, and commit nothing.

d="$(repo)"
printf 'src/\n' >"$d/.gitignore"
git -C "$d" add .gitignore
git -C "$d" commit -q -m ignore
head_before="$(git -C "$d" rev-parse HEAD)"
out="$(cd "$d" && bash "$SCRIPT" --commit 2>&1)"
rc=$?
pass "an ignored file: --commit fails" test "$rc" = 1
pass "an ignored file: the file is named" grep -qF 'sharded-crate/src/lib.rs' <<<"$out"
pass "an ignored file: nothing is committed" test "$(git -C "$d" rev-parse HEAD)" = "$head_before"

# --- the property the workflow relies on -------------------------------------
# A pull request that changes something else entirely: its own commit sits between
# the merge-base and the commit the script makes. The diff against the merge-base
# must still add every line of the crate, so the patch gate has lines to judge.

d="$(repo)"
lines="$(wc -l <"$ROOT/tests/fixtures/shard-crate/src/lib.rs" | tr -d ' ')"
(
  cd "$d" || exit 1
  echo change >unrelated.txt
  git add unrelated.txt
  git commit -q -m 'a pull request that touches nothing measured'
  bash "$SCRIPT" --commit >/dev/null 2>&1
)
mb="$(git -C "$d" merge-base origin/main HEAD)"
added="$(git -C "$d" diff --numstat "$mb" HEAD -- sharded-crate/src/lib.rs | cut -f1)"
pass "merge-base..HEAD adds every line of the crate's source ($lines)" test "$added" = "$lines"
pass "the merge-base is the real one, not the script's commit" test "$mb" = "$(git -C "$d" rev-parse origin/main)"

summary
