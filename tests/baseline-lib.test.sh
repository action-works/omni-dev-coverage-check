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

# The `bash -c` snippets below are single-quoted on purpose: they expand in the child shell.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/tests/baseline-lib.sh"
ASSERT_LIB="$ROOT/tests/assert-lib.sh"
ACTION="$ROOT/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "ok   - $1"
}

bad() {
  failed=$((failed + 1))
  echo "FAIL - $1"
  [ -z "${2:-}" ] || echo "       $2"
}

# eq <name> <expected> <actual>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# has <name> <text> <fragment>: the text contains the fragment (a fixed string).
has() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "no '$3' in: $2"; fi
}

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

step_run() { # <step name>
  awk -v name="$1" '
    $0 == "    - name: " name { in_step = 1; next }
    in_step && /^    - name:/ { exit }
    in_step && $0 == "      run: |" { in_run = 1; next }
    in_run && /^        / { print substr($0, 9); next }
    in_run && $0 == "" { print ""; next }
    in_run { exit }
  ' "$ACTION"
}
DIFF_SCRIPT="$(step_run 'Build coverage diff')"
if [ -z "$DIFF_SCRIPT" ]; then
  echo "FAIL - could not read the diff step out of action.yml"
  exit 1
fi
for expr in report collapse-ranges all-files strip-prefix report-format; do
  case "$expr" in
    report) value=coverage-head.lcov ;;
    collapse-ranges) value=true ;;
    all-files) value=false ;;
    *) value= ;;
  esac
  DIFF_SCRIPT="${DIFF_SCRIPT//"\${{ inputs.$expr }}"/$value}"
done
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
      COMMIT_URL=https://example/commit BASELINE_SHA="$2" BASELINE_DISTANCE="$1" \
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

# A stub for tests/expected-baseline.sh that says what the case wants it to.
STUB="$WORK/expected-stub.sh"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_EXPECTED:-}" ] || exit 1
echo "$FAKE_EXPECTED"
EOF
printf 'TN:aaaaaaaaaaaaaaaaaaaa\nSF:/x\nend_of_record\n' >"$WORK/found.lcov"

# held <label> <pass|fail> <answer> <baseline file, or "none">
held() {
  local label="$1" want="$2" answer="$3" baseline="$4"
  [ "$baseline" != none ] || baseline="$WORK/no-such.lcov"
  lib 'held_to_the_api S ci.yml coverage-baseline 0123456789abcdef "'"$baseline"'"' "expected_baseline=$STUB" "FAKE_EXPECTED=$answer"
  if [ "$want" = pass ]; then eq "$label" 0 "$STATUS"; else eq "$label" 1 "$STATUS"; fi
}
held "held: a hit, and the baseline is the commit the API names" pass "hit aaaaaaaaaaaaaaaaaaaa 2" "$WORK/found.lcov"
held "held: a hit, but the baseline is another commit's (not the nearest)" fail "hit bbbbbbbbbbbbbbbbbbbb 2" "$WORK/found.lcov"
held "held: a hit that the lookup missed" fail "hit aaaaaaaaaaaaaaaaaaaa 2" none
held "held: a miss, and the lookup found nothing" pass "miss" none
held "held: a miss, but the lookup found a baseline" fail "miss" "$WORK/found.lcov"
held "held: either, and the lookup found one" pass "either" "$WORK/found.lcov"
held "held: either, and the lookup found none" pass "either" none
held "held: the check could not ask the API at all" fail "" none
has "held: and says so" "$OUT" "did tests/expected-baseline.sh fail?"
held "held: a baseline with no TN: line is not the commit the API names" fail "hit aaaaaaaaaaaaaaaaaaaa 2" "$WORK/none.lcov"
lib 'held_to_the_api S ci.yml coverage-baseline 0123456789abcdef "'"$WORK/found.lcov"'"' "expected_baseline=$STUB" "FAKE_EXPECTED=hit aaaaaaaaaaaaaaaaaaaa 2"
has "held: it reports what it expected and what it saw" "$OUT" "expected hit aaaaaaa, 2 back, observed hit aaaaaaa"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
