#!/usr/bin/env bash
# Tests for what the "Compute baseline from merge-base (fallback)" step does with the
# worktree it builds at ../base (#78). Plain bash, no framework:
#   tests/recompute-worktree.test.sh
# Exits non-zero if any case fails.
#
# The step used to leave the worktree, and the merge-base's whole build under it
# (`../base/target`), behind. A second recompute in the same job then stopped at
# `git worktree add` ("already exists"): `pr-paths.yml` removed it by hand between R1 and
# R3, and a caller running the action twice would have hit it. Now the step removes it when
# it ends, however it ends, and clears a stale one before it adds its own.
#
# The step's script is read out of action.yml and run with the REAL git, in a throwaway
# repository (each case has its own, with the worktree as the repository's sibling `base`,
# as in an Actions workspace), against a stub `cargo` that logs where it ran, writes the
# report file the way cargo-llvm-cov does, and fails on request. tests/input-steps.test.sh
# and tests/llvm-cov-ignore-steps.test.sh run the same step against a stub `git` and check
# the arguments; this checks what is on disk afterwards, which a stub git cannot say.

# The script lines matched in the last section are literal text read out of action.yml, with
# `$BASE_SHA` in them: single-quoting them is the point.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# The runner's global git config signs commits and may name an identity: neither belongs here.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

STEP='Compute baseline from merge-base (fallback)'
SCRIPT="$(step_run "$STEP")" || exit 1

# The stub cargo: logs `<cwd> <arguments>` per call, writes the report (`SF:` the directory it
# ran in, which is how the step's path rewrite is shown), and exits 1 on the test run when
# CARGO_FAIL is set (`--no-report` is the merge-base's tests; the report call follows it).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/cargo" <<'EOF'
#!/usr/bin/env bash
echo "$PWD $*" >>"$CARGO_LOG"
if [ -n "${CARGO_FAIL:-}" ] && [[ " $* " == *" --no-report "* ]]; then
  echo "error: a test failed" >&2
  exit 1
fi
prev=''
for a in "$@"; do
  if [ "$prev" = --output-path ]; then
    printf 'SF:%s/src/lib.rs\nDA:1,1\nend_of_record\n' "$PWD" >"$a"
  fi
  prev=$a
done
exit 0
EOF
chmod +x "$WORK/bin/cargo"

CASES=0
# new_case: a workspace that is a git repository with one commit, the worktree's place beside
# it. Sets DIR, WS and BASE_SHA.
new_case() {
  CASES=$((CASES + 1))
  DIR="$WORK/case.$CASES"
  WS="$DIR/ws"
  mkdir -p "$WS"
  git init -q "$WS"
  git -C "$WS" config user.name test
  git -C "$WS" config user.email test@invalid
  git -C "$WS" config commit.gpgsign false
  git -C "$WS" commit -q --allow-empty -m base
  BASE_SHA="$(git -C "$WS" rev-parse HEAD)"
  : >"$DIR/cargo.log"
}

# run_step [VAR=value...]: the step, as `shell: bash` runs it, in the workspace. Extra
# variables override the defaults. Sets RC and STEP_OUT; $DIR/output is its $GITHUB_OUTPUT.
run_step() {
  RC=99
  (
    cd "$WS" || exit 99
    env PATH="$WORK/bin:$PATH" CARGO_LOG="$DIR/cargo.log" GITHUB_WORKSPACE="$WS" \
      GITHUB_OUTPUT="$DIR/output" REPORT=out/head.lcov WORKTREE_SYSTEM_DEPS='' \
      TEST_ARGS='--all-features' BASE_SHA="$BASE_SHA" LLVM_COV_IGNORE_FILENAME_REGEX='' "$@" \
      bash --noprofile --norc -eo pipefail -c "$SCRIPT"
  ) >"$DIR/out" 2>&1
  RC=$?
  STEP_OUT="$(cat "$DIR/out")"
}

# worktrees: how many worktrees the repository lists (the main one counts).
worktrees() {
  git -C "$WS" worktree list --porcelain | grep -c '^worktree '
}

gone() { [ ! -e "$DIR/base" ] && echo gone || echo present; }

# --- a recompute that works ----------------------------------------------------------------

new_case
run_step
eq "a recompute: the step succeeds" 0 "$RC"
eq "a recompute: the worktree is gone afterwards" gone "$(gone)"
eq "a recompute: and git has no record of it" 1 "$(worktrees)"
eq "a recompute: the merge-base's tests ran in it, before it was removed" 2 \
  "$(grep -c "^$DIR/base " "$DIR/cargo.log" || true)"
BASELINE="$WS/baseline/head.lcov"
eq "a recompute: the baseline is written for the diff" yes "$([ -s "$BASELINE" ] && echo yes || echo no)"
eq "a recompute: its paths are the workspace's, not the removed worktree's" \
  "SF:$WS/src/lib.rs" "$(grep '^SF:' "$BASELINE")"
eq "a recompute: it says it recomputed" "recomputed=true" "$(cat "$DIR/output")"
FIRST_BASELINE="$(cat "$BASELINE")"

# The bug (#78): a second recompute in the same job stopped at `git worktree add`. The
# workflow moves the first one's outputs aside between scenarios (tests/move-outputs.sh), so
# the baseline directory is gone for the second.
mv "$WS/baseline" "$WS/baseline.first"
: >"$DIR/cargo.log"
run_step
eq "a second recompute in the same workspace: the step succeeds" 0 "$RC"
eq "a second recompute: it writes the same baseline" "$FIRST_BASELINE" "$(cat "$WS/baseline/head.lcov" 2>/dev/null)"
eq "a second recompute: and removes its worktree too" gone "$(gone)"
eq "a second recompute: git still has no record of one" 1 "$(worktrees)"

# --- a recompute that fails -----------------------------------------------------------------

new_case
run_step CARGO_FAIL=1
eq "a failing test run: the step fails, with its own status" 1 "$RC"
has "a failing test run: and says why" "$STEP_OUT" "error: a test failed"
eq "a failing test run: the worktree is gone all the same" gone "$(gone)"
eq "a failing test run: git has no record of it" 1 "$(worktrees)"
eq "a failing test run: no baseline is left to be read" no "$([ -e "$WS/baseline" ] && echo yes || echo no)"
lacks "a failing test run: and it does not say it recomputed" "$(cat "$DIR/output" 2>/dev/null)" "recomputed=true"
run_step
eq "a retry after it: succeeds, so nothing was left in the way" 0 "$RC"

# --- a worktree an earlier run left ----------------------------------------------------------

# A run cancelled before the step ended on a reused runner: the worktree is registered, with
# the files a build leaves in it.
new_case
git -C "$WS" worktree add -q --detach ../base "$BASE_SHA"
mkdir -p "$DIR/base/target/llvm-cov-target"
echo stale >"$DIR/base/target/llvm-cov-target/leftover"
eq "fixture: the leftover is a registered worktree" 2 "$(worktrees)"
run_step
eq "a registered leftover: the step succeeds" 0 "$RC"
eq "a registered leftover: and its worktree is gone afterwards" gone "$(gone)"
eq "a registered leftover: with one record fewer than it started with" 1 "$(worktrees)"

# Its directory was wiped but git still records it: `git worktree add` refuses that too. On the
# git this was written with (2.50) `remove --force` clears that record by itself, so this case
# does not tell `prune` apart; `prune` is for gits where it does not, and is held as text below.
new_case
git -C "$WS" worktree add -q --detach ../base "$BASE_SHA"
mv "$DIR/base" "$DIR/base.wiped"
eq "fixture: git still records the missing worktree" 2 "$(worktrees)"
run_step
eq "a record with no directory: the step succeeds" 0 "$RC"
eq "a record with no directory: and nothing is left" 1 "$(worktrees)"

# --- a directory that is not a worktree ---------------------------------------------------------

# `base` beside the workspace can be a directory of someone else's. `git worktree remove` only
# touches a worktree it knows, and the trap is set after a successful add, so neither removes
# it: the step fails at the add, as it always did, and the directory is as it was.
new_case
mkdir "$DIR/base"
echo precious >"$DIR/base/keep.txt"
run_step
if [ "$RC" -ne 0 ]; then ok "a plain directory named base: the step fails at the add"; else bad "a plain directory named base: the step fails at the add" "it succeeded"; fi
has "a plain directory named base: and git says why" "$STEP_OUT" "already exists"
eq "a plain directory named base: it is kept, with its file" precious "$(cat "$DIR/base/keep.txt" 2>/dev/null)"
eq "a plain directory named base: no test was run" "" "$(cat "$DIR/cargo.log")"

# --- steps that end before the worktree is made --------------------------------------------------

new_case
mkdir "$DIR/base" "$WS/baseline"
echo precious >"$DIR/base/keep.txt"
echo downloaded >"$WS/baseline/head.lcov"
run_step
eq "a downloaded baseline: the step ends at once" 0 "$RC"
has "a downloaded baseline: and says so" "$STEP_OUT" "a baseline was downloaded; skipping recompute"
eq "a downloaded baseline: it touched nothing at ../base" precious "$(cat "$DIR/base/keep.txt" 2>/dev/null)"
eq "a downloaded baseline: and left the baseline as it was" downloaded "$(cat "$WS/baseline/head.lcov")"

new_case
mkdir "$DIR/base"
echo precious >"$DIR/base/keep.txt"
run_step 'WORKTREE_SYSTEM_DEPS="quoted"'
eq "refused system deps: the step fails" 1 "$RC"
eq "refused system deps: it touched nothing at ../base" precious "$(cat "$DIR/base/keep.txt" 2>/dev/null)"

# --- the order the script has them in ------------------------------------------------------------

# The cases above hold the behaviour; these hold the order it depends on, as text: the stale
# one is cleared before the add, and the trap is set after it, so that the step removes only
# what this run made. (Git would refuse to remove a directory that is not a worktree whichever
# came first, so no case can tell the two orders apart; this is held as text.)
line_of() { grep -n -F -- "$1" <<<"$SCRIPT" | head -n1 | cut -d: -f1; }
CLEAR_AT="$(line_of 'git worktree remove --force ../base 2>/dev/null || true')"
PRUNE_AT="$(line_of 'git worktree prune || true')"
ADD_AT="$(line_of 'git worktree add ../base "$BASE_SHA"')"
TRAP_AT="$(line_of "trap 'git worktree remove --force ../base || true' EXIT")"
pass "script: it clears a stale worktree" test -n "$CLEAR_AT"
pass "script: it prunes the records of missing ones, and a failed prune is not a failure" test -n "$PRUNE_AT"
pass "script: it adds the worktree" test -n "$ADD_AT"
pass "script: it removes the worktree when it ends" test -n "$TRAP_AT"
pass "script: the stale one is cleared before the add" test "${CLEAR_AT:-999}" -lt "${ADD_AT:-0}"
pass "script: the records are pruned before the add" test "${PRUNE_AT:-999}" -lt "${ADD_AT:-0}"
pass "script: the trap is set after the add, not before" test "${TRAP_AT:-0}" -gt "${ADD_AT:-999}"
# The step drops its variables before the merge-base's tests, so the trap must not need any.
eq "script: the trap's command holds no variable" "" "$(grep -F "trap '" <<<"$SCRIPT" | grep -F '$' || true)"

summary
