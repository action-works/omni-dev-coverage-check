#!/usr/bin/env bash
# Tests for tests/expected-baseline.sh. Plain bash, no framework:
#   tests/expected-baseline.test.sh
# Exits non-zero if any case fails.
#
# The script is what pr-paths.yml and e2e-sharded.yml hold the action's baseline lookup to, so
# a mistake in it would either excuse a wrong lookup or fail a right one on a runner, where it
# is slow to find. It runs here against a stub `gh` and throwaway git repositories, with the
# runs and artifacts each case sets up. A case that expects `miss` has a control that differs
# in one thing and expects `hit`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/expected-baseline.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# --- the repository: c1 (oldest) .. c14 (newest) --------------------------------------------

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@invalid
git -C "$REPO" config commit.gpgsign false
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
  echo "$i" >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m "c$i"
  git -C "$REPO" tag "c$i"
done

# sha <tag>: the full SHA of a commit of the repository.
sha() {
  git -C "$REPO" rev-parse "$1^{commit}"
}

# --- the stub gh -------------------------------------------------------------------------------

FAKE="$WORK/fake"
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# `gh api <path>`: answers from files under $FAKE, as the Actions API would.
#   runs-<sha>.list        one JSON run per line      (.../workflows/<wf>/runs?head_sha=<sha>)
#   runs-latest.list       the same, for the unfiltered listing (.../workflows/<wf>/runs?per_page=100)
#   runs-latest.fail       the request for it fails, printing this text on stderr
#   artifacts-<id>.list    one JSON artifact per line (.../runs/<id>/artifacts)
#   artifacts-<id>.fail    the request fails, printing this text on stderr, as `gh` does for an HTTP error
[ "$1" = api ] || { echo "stub gh: unexpected arguments: $*" >&2; exit 99; }
path="$2"
case "$path" in
  *"/actions/workflows/"*)
    if [[ "$path" == *"head_sha="* ]]; then
      sha="${path#*head_sha=}"
      key="runs-${sha%%&*}"
    else
      key=runs-latest
    fi
    wrap=workflow_runs
    ;;
  *"/actions/runs/"*"/artifacts"*)
    id="${path#*/actions/runs/}"
    key="artifacts-${id%%/*}"
    wrap=artifacts
    ;;
  *)
    echo "stub gh: unexpected path $path" >&2
    exit 99
    ;;
esac
if [ -f "$FAKE/$key.fail" ]; then
  cat "$FAKE/$key.fail" >&2
  exit 1
fi
if [ -f "$FAKE/$key.list" ]; then
  jq -s --arg w "$wrap" '{($w): .}' "$FAKE/$key.list"
else
  jq -n --arg w "$wrap" '{($w): []}'
fi
EOF
chmod +x "$BIN/gh"

REPOSITORY=acme/widgets

reset() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
}

# run <tag> <id> <status> <conclusion> [head repository]
run() {
  jq -cn --argjson id "$2" --arg s "$3" --arg c "$4" --arg r "${5:-$REPOSITORY}" --arg sha "$(sha "$1")" \
    '{id: $id, head_sha: $sha, status: $s, conclusion: (if $c == "" then null else $c end), head_repository: {full_name: $r}}' \
    >>"$FAKE/runs-$(sha "$1").list"
}

# latest_run <tag> <id> <status> <conclusion> [head repository]: the same, in the unfiltered listing
# of the latest runs only, as when the filtered listing omitted it (#57).
latest_run() {
  jq -cn --argjson id "$2" --arg s "$3" --arg c "$4" --arg r "${5:-$REPOSITORY}" --arg sha "$(sha "$1")" \
    '{id: $id, head_sha: $sha, status: $s, conclusion: (if $c == "" then null else $c end), head_repository: {full_name: $r}}' \
    >>"$FAKE/runs-latest.list"
}

# artifact <run id> <name> [expired]
artifact() {
  jq -cn --arg n "$2" --argjson e "${3:-false}" '{name: $n, expired: $e}' >>"$FAKE/artifacts-$1.list"
}

# baseline_at <tag> <run id>: a finished, successful run of this repository with the baseline.
baseline_at() {
  run "$1" "$2" completed success
  artifact "$2" coverage-baseline
}

# expected <start tag> [depth]: what the script says. Sets STATUS and ANSWER, with every
# commit SHA shown as the tag it is of, so a case reads as the history it sets up.
expected() {
  local start="$1" args=() line tag
  [ -z "${2:-}" ] || args=("$2")
  ANSWER="$(
    cd "$REPO" && env PATH="$BIN:$PATH" FAKE="$FAKE" GITHUB_REPOSITORY="$REPOSITORY" \
      bash "$SCRIPT" ci.yml coverage-baseline "$(sha "$start")" ${args[@]+"${args[@]}"} 2>&1
  )"
  STATUS=$?
  # `hit <sha> <n>` -> `hit <tag> <n>`
  if [[ "$ANSWER" == "hit "* ]]; then
    line="$ANSWER"
    for tag in c14 c13 c12 c11 c10 c9 c8 c7 c6 c5 c4 c3 c2 c1; do
      line="${line//$(sha "$tag")/$tag}"
    done
    ANSWER="$line"
  fi
}

# --- hit, and which commit ----------------------------------------------------------------------

reset
baseline_at c14 101
expected c14
eq "hit: the merge-base's own" "hit c14 0" "$ANSWER"
eq "hit: the script succeeds" 0 "$STATUS"

reset
baseline_at c12 102
baseline_at c9 103
expected c14
eq "hit: the nearest ancestor, not an older one" "hit c12 2" "$ANSWER"

# --- nothing ---------------------------------------------------------------------------------------

reset
expected c14
eq "miss: no run at all" miss "$ANSWER"
eq "miss: the script still succeeds" 0 "$STATUS"

reset
baseline_at c14 104
run c13 105 completed success # a successful run with no artifact
expected c14
eq "miss's control: the baseline is found" "hit c14 0" "$ANSWER"

# --- depth ---------------------------------------------------------------------------------------------

reset
baseline_at c11 106 # 3 before c14
expected c14 2
eq "depth 2: 3 commits back is out of reach" miss "$ANSWER"
expected c14 3
eq "depth 3, the control: 3 commits back is in reach" "hit c11 3" "$ANSWER"
expected c14 0
eq "depth 0: only the commit itself" miss "$ANSWER"
expected c14 03
eq "a leading zero is decimal" "hit c11 3" "$ANSWER"

# The default is the action's own: 10 at the time of writing, read from action.yml.
reset
baseline_at c4 107 # 10 before c14
expected c14
eq "default depth: 10 commits back is in reach" "hit c4 10" "$ANSWER"
reset
baseline_at c3 108 # 11 before c14
expected c14
eq "default depth: 11 commits back is not" miss "$ANSWER"

# --- which runs count --------------------------------------------------------------------------------------

# The newest run for a commit has no baseline; an older one does.
reset
{
  jq -cn '{id: 202, status: "completed", conclusion: "success", head_repository: {full_name: "acme/widgets"}}'
  jq -cn '{id: 201, status: "completed", conclusion: "success", head_repository: {full_name: "acme/widgets"}}'
} >"$FAKE/runs-$(sha c14).list"
artifact 202 coverage-summary
artifact 201 coverage-baseline
expected c14
eq "shadowing: any run's baseline counts, not the newest run's" "hit c14 0" "$ANSWER"
reset
{
  jq -cn '{id: 202, status: "completed", conclusion: "success", head_repository: {full_name: "acme/widgets"}}'
} >"$FAKE/runs-$(sha c14).list"
artifact 202 coverage-summary
expected c14
eq "shadowing's control, only the run without it" miss "$ANSWER"

reset
run c14 301 completed success
artifact 301 coverage-baseline true
expected c14
eq "expired: an expired artifact is not a baseline" miss "$ANSWER"

reset
run c14 302 completed failure
artifact 302 coverage-baseline
run c14 303 completed cancelled
artifact 303 coverage-baseline
expected c14
eq "a run that did not succeed is not a baseline" miss "$ANSWER"

reset
run c14 304 completed success evil/fork
artifact 304 coverage-baseline
expected c14
eq "a run from a fork is not a baseline" miss "$ANSWER"
reset
run c14 304 completed success "$REPOSITORY"
artifact 304 coverage-baseline
expected c14
eq "a fork's control, the same run from this repository" "hit c14 0" "$ANSWER"

# --- first parents only ----------------------------------------------------------------------------------------

reset
git -C "$REPO" checkout -q -B fp c14
git -C "$REPO" checkout -q -b side
echo s >"$REPO/g"
git -C "$REPO" add g
git -C "$REPO" commit -q -m side
git -C "$REPO" tag sidetip
git -C "$REPO" checkout -q fp
echo m >"$REPO/h"
git -C "$REPO" add h
git -C "$REPO" commit -q -m m
git -C "$REPO" merge -q --no-ff -m merge side
git -C "$REPO" tag merge
baseline_at sidetip 401
expected merge
eq "first parent: a baseline on the merged-in branch is not one" miss "$ANSWER"
reset
baseline_at c14 402
expected merge
eq "first parent's control: the line's own baseline, 2 back" "hit c14 2" "$ANSWER"
git -C "$REPO" checkout -q -f c14 2>/dev/null

# --- a run that has not finished ------------------------------------------------------------------------------

# It is not a baseline yet, for this script as for the lookup. A caller that wants to allow for it
# publishing mid-run asks before and after (tests/baseline-lib.sh).
reset
run c14 501 in_progress ""
baseline_at c12 502
expected c14
eq "unfinished: a run that has not finished is passed over for the next commit's baseline" "hit c12 2" "$ANSWER"
reset
run c14 501 queued ""
expected c14
eq "unfinished: it is not a baseline, so with nothing else this is a miss" miss "$ANSWER"
reset
run c14 503 completed success # finished: the control
artifact 503 coverage-baseline
run c14 504 in_progress ""
expected c14
eq "unfinished's control: the finished run beside it is a baseline" "hit c14 0" "$ANSWER"

# --- a run deleted after it was listed ---------------------------------------------------------------------------

reset
baseline_at c14 601
baseline_at c14 602
echo "gh: Not Found (HTTP 404)" >"$FAKE/artifacts-601.fail"
expected c14
eq "deleted: a run whose artifacts are a 404 is passed over, as the lookup passes over it" "hit c14 0" "$ANSWER"
eq "deleted: the script succeeds" 0 "$STATUS"
reset
baseline_at c14 601
echo "gh: Not Found (HTTP 404)" >"$FAKE/artifacts-601.fail"
baseline_at c13 603
expected c14
eq "deleted: and the walk goes on to the next commit" "hit c13 1" "$ANSWER"

# Any other failure is not an answer, and a check that guessed would pass for nothing.
reset
baseline_at c14 604
echo "gh: Internal Server Error (HTTP 500)" >"$FAKE/artifacts-604.fail"
expected c14
eq "failure: another HTTP error is not guessed at: the script fails" 1 "$STATUS"
has "failure: and shows what gh said" "$ANSWER" "HTTP 500"

# --- the filtered listing is incomplete (#57) -----------------------------------------------------

# A listing filtered by `head_sha` has been seen to return a random subset of its matches. The
# latest runs, unfiltered, are read as well, so a run the filtered listing left out is found.
reset
latest_run c14 701 completed success
artifact 701 coverage-baseline
expected c14
eq "incomplete listing: a run only the latest runs have is a baseline" "hit c14 0" "$ANSWER"
eq "incomplete listing: the script succeeds" 0 "$STATUS"
reset
baseline_at c14 701
expected c14
eq "incomplete listing's control, the run in the filtered listing" "hit c14 0" "$ANSWER"
reset
artifact 701 coverage-baseline
expected c14
eq "incomplete listing's control, the run in neither listing" miss "$ANSWER"

# Without it the oracle would name the farther commit and fail a lookup that was right.
reset
latest_run c14 702 completed success
artifact 702 coverage-baseline
baseline_at c12 703
expected c14
eq "incomplete listing: the nearer commit wins over an ancestor's" "hit c14 0" "$ANSWER"
reset
latest_run c13 704 completed success
artifact 704 coverage-baseline
expected c14
eq "incomplete listing: an ancestor's run in the latest runs is found at its distance" "hit c13 1" "$ANSWER"

# What the latest runs add is held to the same tests as the rest.
for shape in "completed|failure|$REPOSITORY" "completed|cancelled|$REPOSITORY" "in_progress||$REPOSITORY" "completed|success|evil/fork"; do
  IFS='|' read -r st concl repo <<<"$shape"
  reset
  latest_run c14 705 "$st" "$concl" "$repo"
  artifact 705 coverage-baseline
  expected c14
  eq "latest runs: a ${concl:-unfinished} run of $repo is not a baseline" miss "$ANSWER"
done
reset
latest_run c13 706 completed success # another commit's, with the run both listings could have had
artifact 706 coverage-baseline
expected c14 0
eq "latest runs: a run for another commit is not this commit's baseline" miss "$ANSWER"
reset
latest_run c14 707 completed success
artifact 707 coverage-baseline true
expected c14
eq "latest runs: an expired artifact is not a baseline" miss "$ANSWER"

# A run both listings have is one run.
reset
baseline_at c14 708
latest_run c14 708 completed success
expected c14
eq "both listings: one run, found once" "hit c14 0" "$ANSWER"

# A failed call is not an answer, for the latest runs as for the rest.
reset
baseline_at c14 709
echo "gh: Internal Server Error (HTTP 500)" >"$FAKE/runs-latest.fail"
expected c14
eq "latest runs failing: the script fails, as for any call that is not an answer" 1 "$STATUS"
has "latest runs failing: and shows what gh said" "$ANSWER" "HTTP 500"

# --- usage ------------------------------------------------------------------------------------------------------------------

out="$(cd "$REPO" && env PATH="$BIN:$PATH" FAKE="$FAKE" GITHUB_REPOSITORY="$REPOSITORY" bash "$SCRIPT" ci.yml 2>&1)"
STATUS=$?
eq "too few arguments: it fails" 1 "$STATUS"
has "too few arguments: and says how to call it" "$out" "usage: expected-baseline.sh"

summary
