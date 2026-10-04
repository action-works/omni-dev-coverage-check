#!/usr/bin/env bash
# Tests for tests/baseline-lib.sh. Plain bash, no framework:
#   tests/baseline-lib.test.sh
# Exits non-zero if any case fails.
#
# The library is what pr-paths.yml and e2e-sharded.yml hold the baseline lookup to, so what
# matters most is that a check cannot pass when it should not: a comment that claims the wrong
# commit or distance, a baseline that is not the nearest, a lookup that found one when the API
# says there is none. Each failing case has a control that differs in one thing and passes.
#
# One case runs the diff step of action.yml itself, read out of it, and hands what it writes
# to `check_note`. That is what ties the wording the action writes to the wording the check
# looks for: a change to either alone fails here and not on a runner.

# Two helper sets meet here and are kept apart by shells: this file, and its parent shell, use
# test-lib.sh (`ok`, `eq`, `has`, `pass`, ...). The snippets under test run in CHILD shells
# (`lib` below) that source tests/assert-lib.sh and the library instead, because the library
# calls assert-lib's `check` and `assert`. test-lib.sh has no `check` (its command checker is
# `pass`, for this reason), and the two are never sourced into one shell.

# The `bash -c` snippets below are single-quoted on purpose: they expand in the child shell.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/tests/baseline-lib.sh"
ASSERT_LIB="$ROOT/tests/assert-lib.sh"
ACTION="$ROOT/action.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# --- the repository: c1 (oldest) .. c5 (newest) ---------------------------------------------

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@invalid
git -C "$REPO" config commit.gpgsign false
for i in 1 2 3 4 5; do
  echo "$i" >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m "c$i"
  git -C "$REPO" tag "c$i"
done
sha() {
  git -C "$REPO" rev-parse "$1^{commit}"
}

# lib <snippet> [VAR=value...]: runs the snippet in a child shell, in the repository, with the
# assertion library and then this one sourced and `status` 0. Sets OUT (what it printed, both
# streams) and STATUS (0 only if no check failed: the snippet's own `exit "$status"`).
lib() {
  local snippet="$1"
  shift
  OUT="$(
    cd "$REPO" && env "$@" bash -c 'status=0; source "$1"; source "$2"; eval "$3"; exit "$status"' _ \
      "$ASSERT_LIB" "$LIB" "$snippet" 2>&1
  )"
  STATUS=$?
}

# --- distance_of -----------------------------------------------------------------------------

lib 'distance_of "$(git rev-parse c5)" "$(git rev-parse c5)"'
eq "distance_of: a commit is 0 from itself" 0 "$OUT"
lib 'distance_of "$(git rev-parse c5)" "$(git rev-parse c2)"'
eq "distance_of: 3 commits back" 3 "$OUT"
lib 'distance_of "$(git rev-parse c2)" "$(git rev-parse c5)"'
eq "distance_of: a descendant is not on the line before it" "" "$OUT"

# Only first parents: c5, then a merge whose second parent is a branch.
git -C "$REPO" checkout -q -b side c3
echo s >"$REPO/g"
git -C "$REPO" add g
git -C "$REPO" commit -q -m side
git -C "$REPO" tag sidetip
git -C "$REPO" checkout -q c5 2>/dev/null
git -C "$REPO" merge -q --no-ff -m merge sidetip
git -C "$REPO" tag merged
lib 'distance_of "$(git rev-parse merged)" "$(git rev-parse c4)"'
eq "distance_of: the first-parent line is walked: c4 is 2 before the merge" 2 "$OUT"
lib 'distance_of "$(git rev-parse merged)" "$(git rev-parse sidetip)"'
eq "distance_of: a second parent's commit is not on it" "" "$OUT"
git -C "$REPO" checkout -q -f c5 2>/dev/null

# --- tn_of -----------------------------------------------------------------------------------

printf 'TN:aaa\nSF:/x\nend_of_record\nTN:aaa\nSF:/y\nend_of_record' >"$WORK/one.lcov"
printf 'TN:aaa\nSF:/x\nend_of_record\nTN:bbb\nSF:/y\nend_of_record\n' >"$WORK/two.lcov"
printf 'SF:/x\nend_of_record\n' >"$WORK/none.lcov"
lib 'tn_of '"$WORK/one.lcov"
eq "tn_of: every record names it: it is listed once" aaa "$OUT"
lib 'tn_of '"$WORK/two.lcov"
eq "tn_of: two commits are both listed" $'aaa\nbbb' "$OUT"
lib 'tn_of '"$WORK/none.lcov"
eq "tn_of: a report with no TN: line names none" "" "$OUT"

# --- note_for ----------------------------------------------------------------------------------

lib 'note_for 1'
eq "note_for: singular" ", 1 commit before the merge-base, which has none." "$OUT"
lib 'note_for 7'
eq "note_for: plural" ", 7 commits before the merge-base, which has none." "$OUT"

# --- check_note, against the note the real diff step writes -----------------------------------

DIFF_SCRIPT="$(step_run 'Build coverage diff')" || exit 1
# The step reads its inputs from the environment, so there is nothing to fill in: an expression
# left in the script would reach bash as literal text, with its output thrown away below.
if [[ "$DIFF_SCRIPT" == *'${{'* ]]; then
  echo "FAIL - the diff step holds an expression: $(grep -o '\${{[^}]*}}' <<<"$DIFF_SCRIPT" | sort -u | paste -sd' ' -)"
  exit 1
fi
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/omni-dev" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-o markdown"*) printf '# Coverage\nTotal: **71.4%%**\n' ;;
  *"-o json"*) echo '{"patch_coverage":{"percent":80},"project_delta":{"total_after":71.4}}' ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$BIN/omni-dev"

# real_comment <distance> <sha>: the comment the diff step writes when the lookup found a
# baseline for <sha>, <distance> commits back. Prints its path.
real_comment() {
  local dir
  dir="$(mktemp -d "$WORK/diff.XXXXXX")"
  mkdir "$dir/baseline"
  echo TN:x >"$dir/baseline/coverage-head.lcov"
  : >"$dir/output"
  (
    cd "$dir" && PATH="$BIN:$PATH" GITHUB_OUTPUT="$dir/output" ARTIFACT_URL=u RUN_URL=u BASE_SHA=0 HEAD_SHA=0 \
      COMMIT_URL=https://example/commit REPORT=coverage-head.lcov COLLAPSE_RANGES=true ALL_FILES=false \
      STRIP_PREFIX='' REPORT_FORMAT='' IGNORE_FILENAME_REGEX='' BASELINE_SHA="$2" BASELINE_DISTANCE="$1" \
      bash --noprofile --norc -eo pipefail -c "$DIFF_SCRIPT" >/dev/null 2>&1
  )
  echo "$dir/coverage.md"
}

# case_note <label> <pass|fail> <start tag> <baseline tag> <comment distance> <comment sha tag>
case_note() {
  local label="$1" want="$2" start="$3" tn="$4" cdist="$5" csha="$6" comment
  comment="$(real_comment "$cdist" "$(sha "$csha")")"
  OUT="$(
    cd "$REPO" && env bash -c 'status=0; source "$1"; source "$2"; check_note P "$3" "$4" "$5"; exit "$status"' _ \
      "$ASSERT_LIB" "$LIB" "$(sha "$start")" "$(sha "$tn")" "$comment" 2>&1
  )"
  STATUS=$?
  if [ "$want" = pass ]; then
    eq "$label" 0 "$STATUS"
  else
    eq "$label" 1 "$STATUS"
  fi
}

case_note "check_note: the baseline is the start's own and the comment says nothing" pass c5 c5 0 c5
case_note "check_note: 2 back, and the comment says so and names it" pass c5 c3 2 c3
case_note "check_note: 1 back, singular" pass c5 c4 1 c4
case_note "check_note: the start's own baseline, but the comment claims an ancestor" fail c5 c5 2 c3
case_note "check_note: 2 back, but the comment says 1" fail c5 c3 1 c3
case_note "check_note: 2 back, but the comment names another commit" fail c5 c3 2 c2
case_note "check_note: 2 back, but the comment says nothing" fail c5 c3 0 c3

# A baseline for a commit that is not behind the start is not one a lookup from there could use.
OUT="$(
  cd "$REPO" && bash -c 'status=0; source "$1"; source "$2"; check_note P "$3" "$4" /dev/null; exit "$status"' _ \
    "$ASSERT_LIB" "$LIB" "$(sha c3)" "$(sha c5)" 2>&1
)"
STATUS=$?
eq "check_note: a baseline commit that is not on the line fails" 1 "$STATUS"
has "check_note: and says so" "$OUT" "is not on the first-parent line"

# --- held_to_the_api -----------------------------------------------------------------------------

# A stub for tests/expected-baseline.sh: what the API says now.
STUB="$WORK/expected-stub.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_EXPECTED:-}" ] || exit 1
echo "$FAKE_EXPECTED"
EOF

# answer <answer>: `miss`, or `hit:<tag>:<distance>` as the stub or the snapshot prints it.
answer() {
  case "$1" in
    hit:*)
      IFS=: read -r _ tag dist <<<"$1"
      echo "hit $(sha "$tag") $dist"
      ;;
    *) echo "$1" ;;
  esac
}

# held <label> <pass|fail> <before> <after> <found: none|<tag>>: a lookup from c5 that downloaded
# the baseline for <tag> (or nothing), held to the API's answers before the scenarios and after.
held() {
  local label="$1" want="$2" before="$3" after="$4" found="$5" baseline="$WORK/no-such.lcov"
  if [ "$found" != none ]; then
    baseline="$WORK/found.lcov"
    printf 'TN:%s\nSF:/x\nend_of_record\n' "$(sha "$found")" >"$baseline"
  fi
  if [ "$before" = none ]; then rm -f "$WORK/snapshot"; else answer "$before" >"$WORK/snapshot"; fi
  lib 'held_to_the_api S ci.yml coverage-baseline "$(git rev-parse c5)" "'"$baseline"'" "'"$WORK/snapshot"'"' \
    "expected_baseline=$STUB" "FAKE_EXPECTED=$(answer "$after")"
  if [ "$want" = pass ]; then eq "$label" 0 "$STATUS"; else eq "$label" 1 "$STATUS"; fi
}

# Nothing changed while the scenarios ran: exact.
held "held: stable, a hit 2 back: the lookup found it" pass hit:c3:2 hit:c3:2 c3
held "held: stable: found a nearer one than the API knows of" fail hit:c3:2 hit:c3:2 c4
held "held: stable: found a farther one than the API says is nearest" fail hit:c3:2 hit:c3:2 c2
held "held: stable: a hit the lookup missed" fail hit:c3:2 hit:c3:2 none
held "held: stable, a miss: the lookup found nothing" pass miss miss none
held "held: stable, a miss: but the lookup found a baseline" fail miss miss c3
held "held: stable, the merge-base's own: found" pass hit:c5:0 hit:c5:0 c5
held "held: stable, the merge-base's own: but the lookup went back" fail hit:c5:0 hit:c5:0 c3

# A baseline was published while the scenarios ran (the push run for the merge-base finished):
# the lookup may have seen it or not.
held "held: published meanwhile, 2 back before and 0 after: the lookup found the older one" pass hit:c3:2 hit:c5:0 c3
held "held: published meanwhile: the lookup found the new one" pass hit:c3:2 hit:c5:0 c5
held "held: published meanwhile: but found none at all, which was never true" fail hit:c3:2 hit:c5:0 none
held "held: nothing before and one after: the lookup found nothing" pass miss hit:c5:0 none
held "held: nothing before and one after: the lookup found it" pass miss hit:c5:0 c5
# One expired meanwhile: the two answers swap, and either is fair.
held "held: expired meanwhile: the lookup found the one that was there" pass hit:c5:0 hit:c3:2 c5

# A snapshot that was never taken, or an API that cannot be asked, is not a pass.
held "held: no snapshot to hold the lookup to" fail none miss none
has "held: and it says so" "$OUT" "did tests/expected-baseline.sh fail?"
answer miss >"$WORK/snapshot"
lib 'held_to_the_api S ci.yml coverage-baseline "$(git rev-parse c5)" "'"$WORK/no-such.lcov"'" "'"$WORK/snapshot"'"' "expected_baseline=$STUB" "FAKE_EXPECTED="
eq "held: the API cannot be asked now" 1 "$STATUS"
has "held: and it says so too" "$OUT" "did tests/expected-baseline.sh fail?"

printf 'SF:/x\nend_of_record\n' >"$WORK/notn.lcov"
answer hit:c3:2 >"$WORK/snapshot"
lib 'held_to_the_api S ci.yml coverage-baseline "$(git rev-parse c5)" "'"$WORK/notn.lcov"'" "'"$WORK/snapshot"'"' "expected_baseline=$STUB" "FAKE_EXPECTED=$(answer hit:c3:2)"
eq "held: a baseline with no TN: line is not any commit's" 1 "$STATUS"

held "held: it says what was expected and found" pass hit:c3:2 hit:c3:2 c3
lib 'held_to_the_api S ci.yml coverage-baseline "$(git rev-parse c5)" "'"$WORK/found.lcov"'" "'"$WORK/snapshot"'"' "expected_baseline=$STUB" "FAKE_EXPECTED=$(answer hit:c3:2)"
has "held: the notice names the commit found and how far back" "$OUT" "the lookup found the baseline for $(sha c3 | cut -c1-7) (2 back)"

summary
