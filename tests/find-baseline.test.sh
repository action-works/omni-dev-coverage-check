#!/usr/bin/env bash
# Tests for scripts/find-baseline.sh. Plain bash, no framework:
#   tests/find-baseline.test.sh
# Exits non-zero if any case fails.
#
# The script runs in a throwaway git repository, against a stub `curl` that serves the
# runs and artifacts each case sets up and logs every request it is sent, so no case
# touches the network and a case can say how many requests a lookup spent. The shapes
# the stub serves (`workflow_runs[].conclusion`, `.head_repository.full_name`,
# `artifacts[].expired`, and a 404 for a workflow the API does not know) are those of the
# real API, which the script was also run against once, by hand.
#
# Each case that expects a miss, a skip or a failure has a control that differs in one
# thing and must find the baseline, so a lookup that finds nothing for every input cannot
# pass.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/find-baseline.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# --- the repository: c1 (oldest) .. c12 (newest), one commit after another ----------

REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@invalid
git -C "$REPO" config commit.gpgsign false
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  echo "$i" >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m "c$i"
  git -C "$REPO" tag "c$i"
done

# sha <tag>: the full SHA of a commit of the repository.
sha() {
  git -C "$REPO" rev-parse "$1^{commit}"
}

# --- the stub curl ---------------------------------------------------------------------

FAKE="$WORK/fake"
CURL_LOG="$WORK/curl.log"
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Answers the two kinds of request the script makes from files under $FAKE:
#   runs-<sha>.list        one JSON run per line      (GET .../workflows/<wf>/runs?head_sha=<sha>)
#   runs-latest.list       the same, for the unfiltered listing (GET .../workflows/<wf>/runs?per_page=100)
#   artifacts-<id>.list    one JSON artifact per line (GET .../runs/<id>/artifacts)
#   <that name>.status     an HTTP status to answer instead, with <name>.json as the body
#   <that name>.sequence   statuses, one line per request, answered first (200: serve normally)
#   workflow.status        the status every runs request is answered with (404: no such workflow)
# The status goes after the body, on a line of its own, as the script asks with -w.
args="$*"
echo "${args//$'\n'/ }" >>"$CURL_LOG" # one line per request: the -w argument holds a newline
url="${!#}"
if [ -n "${FAKE_CURL_EXIT:-}" ]; then
  # As the real curl does: -w still prints 000, but a transport failure exits non-zero.
  printf '\n000'
  exit "$FAKE_CURL_EXIT"
fi
case "$url" in
  *"/actions/workflows/"*)
    if [[ "$url" == *"head_sha="* ]]; then
      sha="${url#*head_sha=}"
      key="runs-${sha%%&*}"
    else
      key=runs-latest
    fi
    wrap=workflow_runs
    ;;
  *"/actions/runs/"*"/artifacts"*)
    id="${url#*/actions/runs/}"
    key="artifacts-${id%%/*}"
    wrap=artifacts
    ;;
  *)
    echo "stub curl: unexpected URL $url" >&2
    exit 99
    ;;
esac
status=200
body=
if [ -s "$FAKE/$key.sequence" ]; then
  status="$(head -n1 "$FAKE/$key.sequence")"
  tail -n +2 "$FAKE/$key.sequence" >"$FAKE/$key.sequence.next"
  mv "$FAKE/$key.sequence.next" "$FAKE/$key.sequence"
  if [ "$status" != 200 ]; then
    printf '{"message":"stub: %s"}\n%s' "$status" "$status"
    exit 0
  fi
fi
if [ -f "$FAKE/$key.status" ]; then
  status="$(cat "$FAKE/$key.status")"
  [ ! -f "$FAKE/$key.json" ] || body="$(cat "$FAKE/$key.json")"
elif [ "$wrap" = workflow_runs ] && [ -f "$FAKE/workflow.status" ]; then
  status="$(cat "$FAKE/workflow.status")"
  body='{"message":"Not Found"}'
else
  if [ -f "$FAKE/$key.list" ]; then
    body="$(jq -s --arg w "$wrap" '{($w): .}' "$FAKE/$key.list")"
  else
    body="$(jq -n --arg w "$wrap" '{($w): []}')"
  fi
fi
printf '%s\n%s' "$body" "$status"
EOF
chmod +x "$BIN/curl"

# --- building a case ----------------------------------------------------------------------

REPOSITORY=acme/widgets

reset() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE"
  : >"$CURL_LOG"
}

# run <tag> <id> <conclusion> [head repository]: a run of the workflow for a commit.
run() {
  jq -cn --argjson id "$2" --arg c "$3" --arg r "${4:-$REPOSITORY}" --arg sha "$(sha "$1")" \
    '{id: $id, head_sha: $sha, conclusion: $c, status: "completed", head_repository: {full_name: $r}}' \
    >>"$FAKE/runs-$(sha "$1").list"
}

# latest_run <tag> <id> <conclusion> [head repository]: the same run, as the unfiltered listing
# of the workflow's latest runs has it. A case that wants the filtered listing to have omitted it
# calls only this; the filtered listing is the one whose answer is incomplete (#57).
latest_run() {
  jq -cn --argjson id "$2" --arg c "$3" --arg r "${4:-$REPOSITORY}" --arg sha "$(sha "$1")" \
    '{id: $id, head_sha: $sha, conclusion: $c, status: "completed", head_repository: {full_name: $r}}' \
    >>"$FAKE/runs-latest.list"
}

# artifact <run id> <name> [expired]
artifact() {
  jq -cn --arg n "$2" --argjson e "${3:-false}" '{name: $n, expired: $e}' >>"$FAKE/artifacts-$1.list"
}

# baseline_at <tag> <run id>: a successful run of this repository that holds the baseline.
baseline_at() {
  run "$1" "$2" success
  artifact "$2" coverage-baseline
}

# sequence <key> <status>...: answer the first requests for a key with these statuses, in order.
sequence() {
  local key="$1"
  shift
  printf '%s\n' "$@" >"$FAKE/$key.sequence"
}

# fail_with <key> <status> [body]: answer every request for a key with an HTTP status.
fail_with() {
  echo "$2" >"$FAKE/$1.status"
  [ -z "${3:-}" ] || echo "$3" >"$FAKE/$1.json"
}

# lookup <start> <depth> [VAR=value...]: runs the script in the repository the way the step
# does. Sets STATUS, STDOUT (both streams), OUT (what it wrote to $GITHUB_OUTPUT), and leaves
# the requests it made in $CURL_LOG. A later VAR=value overrides an earlier one.
lookup() {
  local start="$1" depth="$2"
  shift 2
  : >"$WORK/output"
  STDOUT="$(
    cd "$REPO" && env PATH="$BIN:$PATH" GITHUB_OUTPUT="$WORK/output" GITHUB_REPOSITORY="$REPOSITORY" \
      GITHUB_API_URL=https://api.github.com BASELINE_WORKFLOW=ci.yml BASELINE_ARTIFACT=coverage-baseline \
      BASE_REF="$start" ANCESTOR_DEPTH="$depth" GH_TOKEN=tok FAKE="$FAKE" CURL_LOG="$CURL_LOG" \
      FIND_BASELINE_RETRY_DELAY=0 \
      "$@" bash "$SCRIPT" 2>&1
  )"
  STATUS=$?
  OUT="$(cat "$WORK/output")"
}

# out <key>: a value the script wrote to $GITHUB_OUTPUT.
out() {
  sed -n "s/^$1=//p" <<<"$OUT" | head -n1
}

requests() {
  wc -l <"$CURL_LOG" | tr -d ' '
}

# asked <fragment>: how many requests had the fragment in them.
asked() {
  grep -cF -- "$1" "$CURL_LOG" || true
}

# --- the merge-base itself ----------------------------------------------------------------

reset
baseline_at c12 101
lookup c12 10
eq "exact: the script succeeds" 0 "$STATUS"
eq "exact: found" true "$(out found)"
eq "exact: the run that holds the artifact" 101 "$(out run-id)"
eq "exact: the commit it was published for" "$(sha c12)" "$(out sha)"
eq "exact: distance 0" 0 "$(out distance)"
eq "exact: it did not walk once it had found it (one runs request, one artifacts request)" 2 "$(requests)"
has "exact: it asks for this commit's successful runs of the workflow" "$(cat "$CURL_LOG")" \
  "https://api.github.com/repos/acme/widgets/actions/workflows/ci.yml/runs?head_sha=$(sha c12)&status=success&per_page=100"
has "exact: it asks for the artifact by name in that run" "$(cat "$CURL_LOG")" \
  "/actions/runs/101/artifacts?name=coverage-baseline&per_page=100"
lacks "exact: no notice that an ancestor was used" "$STDOUT" "::notice::"
lacks "exact: no warning" "$STDOUT" "::warning::"

# --- the nearest ancestor ------------------------------------------------------------------

reset
baseline_at c10 102
baseline_at c8 103
lookup c12 10
eq "ancestor: found" true "$(out found)"
eq "ancestor: the nearest one wins, not an older one" "$(sha c10)" "$(out sha)"
eq "ancestor: its run" 102 "$(out run-id)"
eq "ancestor: two commits before the merge-base" 2 "$(out distance)"
has "ancestor: the notice names both commits and the distance" "$STDOUT" \
  "::notice::No baseline 'coverage-baseline' for $(sha c12 | cut -c1-7); using the one for $(sha c10 | cut -c1-7), 2 commits before it (run 102)"
eq "ancestor: it stopped at the first one found (3 runs requests, 1 for the latest runs, 1 artifacts request)" 5 "$(requests)"

reset
baseline_at c11 104
lookup c12 10
eq "ancestor: one commit before, singular" 1 "$(out distance)"
has "ancestor: '1 commit', not '1 commits'" "$STDOUT" "1 commit before it"
lacks "ancestor: '1 commit', not '1 commits'" "$STDOUT" "1 commits"

# --- depth ------------------------------------------------------------------------------------

reset
baseline_at c11 105
lookup c12 0
eq "depth 0: the ancestor's baseline is not used" false "$(out found)"
eq "depth 0: it is not an error" 0 "$STATUS"
eq "depth 0: it asked about the merge-base only" 1 "$(asked 'head_sha=')"
eq "depth 0: and, as it had no baseline, for the latest runs once" 1 "$(asked 'runs?per_page=100')"
has "depth 0: the warning names the commit" "$STDOUT" "::warning::No baseline 'coverage-baseline' was published by workflow 'ci.yml' for $(sha c12 | cut -c1-7). Continuing without one."
lookup c12 1
eq "depth 0's control, depth 1: the same baseline is found" true "$(out found)"

reset
baseline_at c9 106 # three commits before c12
lookup c12 2
eq "depth 2: a baseline 3 commits back is out of reach" false "$(out found)"
eq "depth 2: it tried the merge-base and 2 ancestors" 3 "$(asked 'head_sha=')"
has "depth 2: the warning says how far it looked" "$STDOUT" "for $(sha c12 | cut -c1-7) or the 2 ancestors checked before it"
lookup c12 3
eq "depth 3, the control: the baseline 3 commits back is found" true "$(out found)"
eq "depth 3: distance 3" 3 "$(out distance)"

reset
lookup c12 010
eq "a leading zero is decimal: depth 010 tries 11 commits, not 8" 11 "$(asked 'head_sha=')"
reset
lookup c12 ''
eq "an empty depth is 0" 1 "$(asked 'head_sha=')"

reset
lookup c12 -1
eq "a negative depth is a usage error" 2 "$STATUS"
has "a negative depth names the input" "$STDOUT" "::error::baseline-ancestor-depth must be a whole number of commits"
lookup c12 ten
eq "a word is a usage error" 2 "$STATUS"
lookup c12 1.5
eq "a fraction is a usage error" 2 "$STATUS"
eq "a usage error makes no request" 0 "$(requests)"

# A history shorter than the depth: the walk stops at the first commit.
reset
git -C "$REPO" checkout -q --orphan short
git -C "$REPO" commit -q --allow-empty -m s1
git -C "$REPO" commit -q --allow-empty -m s2
git -C "$REPO" commit -q --allow-empty -m s3
lookup short 10
eq "a short history: it tried each of the 3 commits and no more" 3 "$(asked 'head_sha=')"
has "a short history: the warning counts the ancestors it had" "$STDOUT" "or the 2 ancestors checked before it"
git -C "$REPO" checkout -q -f c12 2>/dev/null

# --- only the first parent -----------------------------------------------------------------

# main:    c12 ---------- M
#            \           /
# feature:    f1 ------- (second parent of M)
reset
git -C "$REPO" checkout -q -B first-parent c12
git -C "$REPO" checkout -q -b feature
echo f1 >"$REPO/g"
git -C "$REPO" add g
git -C "$REPO" commit -q -m f1
git -C "$REPO" tag f1
git -C "$REPO" checkout -q first-parent
echo m1 >"$REPO/h"
git -C "$REPO" add h
git -C "$REPO" commit -q -m m1
git -C "$REPO" merge -q --no-ff -m M feature
git -C "$REPO" tag M
baseline_at f1 107 # on the merged branch only
lookup M 10
eq "first parent: a baseline on a merged-in branch is not found" false "$(out found)"
reset
baseline_at c12 108 # where the branch started: on the first-parent line
lookup M 10
eq "first parent, the control: the line's own baseline is found" true "$(out found)"
eq "first parent: it is 2 commits before the merge (m1, then c12)" 2 "$(out distance)"
git -C "$REPO" checkout -q -f c12 2>/dev/null

# --- a successful run with no baseline must not hide the one that has it ----------------

reset
run c12 201 success # older: published the baseline
artifact 201 coverage-baseline
# The API lists newest first, so the run with no baseline comes first.
tmp="$(mktemp "$WORK/x.XXXXXX")"
{
  jq -cn '{id: 202, conclusion: "success", status: "completed", head_repository: {full_name: "acme/widgets"}}'
  cat "$FAKE/runs-$(sha c12).list"
} >"$tmp"
mv "$tmp" "$FAKE/runs-$(sha c12).list"
artifact 202 coverage-summary # it has artifacts, just not that one
lookup c12 0
eq "shadowing: the older run's baseline is found past the newer run that has none" 201 "$(out run-id)"
eq "shadowing: it is still the merge-base's own" 0 "$(out distance)"

reset
run c12 202 success
artifact 202 coverage-summary
lookup c12 0
eq "shadowing's control, only the run without it: nothing is found" false "$(out found)"

# --- an expired artifact is not a baseline ---------------------------------------------------

reset
run c12 301 success
artifact 301 coverage-baseline true
baseline_at c11 302
lookup c12 0
eq "expired: an expired artifact is not found" false "$(out found)"
lookup c12 1
eq "expired: the walk goes on to the ancestor's live one" "$(sha c11)" "$(out sha)"
reset
baseline_at c12 301
lookup c12 0
eq "expired's control: the same artifact, not expired, is found" true "$(out found)"

# --- which runs count --------------------------------------------------------------------------

reset
run c12 401 failure
artifact 401 coverage-baseline
run c12 402 cancelled
artifact 402 coverage-baseline
lookup c12 0
eq "a run that did not succeed is skipped, whatever it uploaded" false "$(out found)"

reset
run c12 403 success evil/fork
artifact 403 coverage-baseline
lookup c12 0
eq "a run from a fork is skipped: it could have uploaded anything" false "$(out found)"
reset
run c12 403 success "$REPOSITORY"
artifact 403 coverage-baseline
lookup c12 0
eq "a fork's control, the same run from this repository, is found" true "$(out found)"

# A run deleted after it was listed: its artifacts are a 404. The next run is tried.
reset
baseline_at c12 404
baseline_at c12 405
fail_with artifacts-404 404 '{"message":"Not Found"}'
lookup c12 0
eq "a run deleted after it was listed is passed over" 405 "$(out run-id)"

# --- a workflow the API does not know ---------------------------------------------------------

reset
baseline_at c11 501
echo 404 >"$FAKE/workflow.status"
lookup c12 10 BASELINE_WORKFLOW=not-yet.yml
eq "no such workflow: the script succeeds" 0 "$STATUS"
eq "no such workflow: it is a miss" false "$(out found)"
has "no such workflow: the warning names the workflow" "$STDOUT" "::warning::Workflow 'not-yet.yml' was not found in acme/widgets (HTTP 404)"
has "no such workflow: and says to continue" "$STDOUT" "Continuing without a baseline."
lacks "no such workflow: not an error" "$STDOUT" "::error::"
eq "no such workflow: the walk stopped at once: every commit would 404 alike" 1 "$(requests)"
has "no such workflow: it asked for that workflow" "$(cat "$CURL_LOG")" "/actions/workflows/not-yet.yml/runs"
reset
baseline_at c11 501
lookup c12 10 BASELINE_WORKFLOW=not-yet.yml
eq "no such workflow's control, the workflow exists: the ancestor's baseline is found" true "$(out found)"

# --- any other failure is not "there is none" -------------------------------------------------

reset
baseline_at c12 601
fail_with "runs-$(sha c12)" 403 '{"message":"Resource not accessible by integration"}'
lookup c12 10
eq "403 on the runs: the script fails" 1 "$STATUS"
has "403 on the runs: the error carries the status and the API's message" "$STDOUT" \
  "::error::Could not list the runs of workflow 'ci.yml' (HTTP 403: Resource not accessible by integration)"
eq "403 on the runs: nothing was written" "" "$OUT"
eq "403 on the runs: no walk past it" 1 "$(requests)"

reset
baseline_at c12 601
fail_with "runs-$(sha c12)" 500
lookup c12 10
eq "500 on the runs: the script fails" 1 "$STATUS"
has "500 on the runs: with the status, and no message to quote" "$STDOUT" "(HTTP 500)."

reset
baseline_at c12 601
fail_with artifacts-601 500
lookup c12 10
eq "500 on the artifacts: the script fails" 1 "$STATUS"
has "500 on the artifacts: the error names the run" "$STDOUT" "list the artifacts of run 601"

reset
baseline_at c12 601
lookup c12 10 FAKE_CURL_EXIT=7
eq "no response: the script fails" 1 "$STATUS"
has "no response: and says to re-run" "$STDOUT" "no response from https://api.github.com. Re-run the job."
reset
baseline_at c12 601
lookup c12 10
eq "a failure's control, the same lookup with a response: found" true "$(out found)"

# --- transient errors are tried again --------------------------------------------------------

reset
baseline_at c12 901
sequence "runs-$(sha c12)" 502 200
lookup c12 10
eq "retry: one 502 and then an answer: found" true "$(out found)"
eq "retry: the retry is the same request again (502, then runs, then artifacts)" 3 "$(requests)"
lacks "retry: no error for a blip" "$STDOUT" "::error::"

for transient in 500 503 429 000; do
  reset
  baseline_at c12 901
  if [ "$transient" = 000 ]; then
    lookup c12 10 FAKE_CURL_EXIT=7
  else
    fail_with "runs-$(sha c12)" "$transient"
    lookup c12 10
  fi
  eq "retry: $transient every time: gives up after 3 attempts, at the first request: an error" 1 "$STATUS"
  eq "retry: $transient: three attempts, no more" 3 "$(requests)"
done

# What is not transient is not asked twice.
for definite in 403 404 401 422; do
  reset
  baseline_at c12 901
  fail_with "runs-$(sha c12)" "$definite" '{"message":"no"}'
  lookup c12 10
  eq "retry: $definite is an answer, so it is asked once" 1 "$(requests)"
done

# --- an error deeper in the walk is a miss, the first request's is an error ------------------------

reset
baseline_at c10 902
lookup c12 10
eq "deep: control, nothing wrong: the baseline 2 back is found" true "$(out found)"

for deep in 500 403; do
  reset
  baseline_at c10 902
  fail_with "runs-$(sha c11)" "$deep" '{"message":"stub failure"}'
  lookup c12 10
  eq "deep: HTTP $deep one commit back: the script succeeds" 0 "$STATUS"
  eq "deep: HTTP $deep: it is a miss" false "$(out found)"
  has "deep: HTTP $deep: the warning says what failed and when" "$STDOUT" \
    "::warning::Could not list the runs of workflow 'ci.yml' (HTTP $deep: stub failure), after the merge-base itself was looked up. Continuing without a baseline."
  lacks "deep: HTTP $deep: not an error" "$STDOUT" "::error::"
done

reset
baseline_at c11 903
fail_with artifacts-903 500
lookup c12 10
eq "deep: the artifacts of an ancestor's run failing: a miss, the merge-base's own request having worked" false "$(out found)"
has "deep: and the warning names the run" "$STDOUT" "list the artifacts of run 903"
reset
baseline_at c12 903
fail_with artifacts-903 500
lookup c12 10
eq "deep's contrast: the same failure on the merge-base's own run is an error" 1 "$STATUS"

# No response at all, three times running, one commit back.
reset
baseline_at c10 905
sequence "runs-$(sha c11)" 000 000 000
lookup c12 10
eq "deep: no response one commit back (after 3 attempts) is also a miss" 0 "$STATUS"
eq "deep: no response: not found" false "$(out found)"
has "deep: no response: the warning says so" "$STDOUT" "no response from https://api.github.com), after the merge-base itself was looked up"
# ... but one lost response is retried and the walk goes on.
reset
baseline_at c10 905
sequence "runs-$(sha c11)" 000
lookup c12 10
eq "deep's control: one lost response is retried, and the baseline 2 back is found" true "$(out found)"

# --- a runner without a tool the lookup needs -----------------------------------------------------------

# A PATH with git and the stub curl and nothing else: no jq.
NOJQ="$WORK/nojq"
mkdir "$NOJQ"
ln -s "$(command -v git)" "$NOJQ/git"
ln -s "$BIN/curl" "$NOJQ/curl"
reset
baseline_at c12 904
: >"$WORK/output"
STDOUT="$(
  cd "$REPO" && env PATH="$NOJQ" GITHUB_OUTPUT="$WORK/output" GITHUB_REPOSITORY="$REPOSITORY" \
    BASELINE_WORKFLOW=ci.yml BASELINE_ARTIFACT=coverage-baseline BASE_REF="$(sha c12)" ANCESTOR_DEPTH=3 \
    FAKE="$FAKE" CURL_LOG="$CURL_LOG" "$(command -v bash)" "$SCRIPT" 2>&1
)"
STATUS=$?
OUT="$(cat "$WORK/output")"
eq "no jq: the script still succeeds" 0 "$STATUS"
eq "no jq: it is a miss" false "$(out found)"
has "no jq: the warning names the missing tool, not a missing workflow" "$STDOUT" \
  "::warning::jq was not found on PATH, and the baseline lookup needs it. Continuing without a baseline."
lacks "no jq: and does not blame the workflow" "$STDOUT" "was not found in"
eq "no jq: it asked nothing of the API" 0 "$(requests)"

# --- the commit to start from -----------------------------------------------------------------

reset
baseline_at c11 701
lookup HEAD~1 0 # a ref, not a SHA: it is resolved first
eq "the start may be any revision: HEAD~1 is c11" "$(sha c11)" "$(out sha)"

reset
lookup 0000000000000000000000000000000000000001 5
eq "a start that is not a commit: a miss, not an error" 0 "$STATUS"
eq "a start that is not a commit: found=false" false "$(out found)"
has "a start that is not a commit: the warning names it" "$STDOUT" "::warning::Could not resolve '0000000000000000000000000000000000000001' to a commit"
eq "a start that is not a commit: no request was made" 0 "$(requests)"

# --- how it talks to the API -----------------------------------------------------------------

reset
baseline_at c12 801
lookup c12 0
has "the token is sent" "$(cat "$CURL_LOG")" "Authorization: Bearer tok"
: >"$CURL_LOG"
lookup c12 0 GH_TOKEN=
lacks "no token, no Authorization header" "$(cat "$CURL_LOG")" "Authorization"
eq "no token, the control's requests were all logged" 2 "$(requests)"
eq "no token: it still looks" true "$(out found)"

reset
baseline_at c12 802
lookup c12 0 GITHUB_API_URL=https://ghes.example/api/v3
has "GITHUB_API_URL is the root, so GitHub Enterprise Server works" "$(cat "$CURL_LOG")" \
  "https://ghes.example/api/v3/repos/acme/widgets/actions/workflows/ci.yml/runs"

# The artifact name and the workflow are data: encoded, never part of the URL's syntax.
reset
run c12 803 success
artifact 803 "my baseline&x=1"
lookup c12 0 "BASELINE_ARTIFACT=my baseline&x=1"
eq "a name with a space and an ampersand is found" true "$(out found)"
has "a name is URL-encoded in the request" "$(cat "$CURL_LOG")" "artifacts?name=my%20baseline%26x%3D1&per_page=100"

# --- the filtered listing is incomplete (#57) -----------------------------------------------------

# With `head_sha` or `status` given, the API has been seen to return a random subset of the
# runs it matches, and nothing in the answer shows the gap. A candidate with no baseline in
# that listing is looked up again in the workflow's latest runs, which are fetched once.
short() { sha "$1" | cut -c1-7; }

reset
latest_run c12 1001 success
artifact 1001 coverage-baseline
lookup c12 0
eq "incomplete listing: the run only the latest runs have is found" true "$(out found)"
eq "incomplete listing: its run" 1001 "$(out run-id)"
eq "incomplete listing: it is still the merge-base's own" 0 "$(out distance)"
eq "incomplete listing: the commit it was published for" "$(sha c12)" "$(out sha)"
has "incomplete listing: it says it published it for the merge-base, not an ancestor" "$STDOUT" \
  "Baseline 'coverage-baseline': run 1001 published it for $(short c12)."
lacks "incomplete listing: no notice that an ancestor was used" "$STDOUT" "::notice::"
eq "incomplete listing: its requests are the runs, the latest runs and the artifacts" 3 "$(requests)"
has "incomplete listing: the line says what each listing held" "$STDOUT" \
  "Candidate $(short c12) (0 back): the listing returned 0 runs, 0 successful from this repository; none holds a live 'coverage-baseline'. The latest runs add 1 such run; run 1001 holds one."

# Its controls, each differing in one thing. The run in the filtered listing: found, and the
# latest runs cost nothing, since nothing needed them.
reset
baseline_at c12 1001
lookup c12 0
eq "incomplete listing's control, the run in the filtered listing: found" true "$(out found)"
eq "incomplete listing's control: the latest runs were not asked for" 0 "$(asked 'runs?per_page=100')"
eq "incomplete listing's control: two requests, as before" 2 "$(requests)"
has "incomplete listing's control: the line names the run" "$STDOUT" \
  "Candidate $(short c12) (0 back): the listing returned 1 run, 1 successful from this repository; run 1001 holds a live 'coverage-baseline'."
# The run in neither listing: a miss, so the find above is the latest runs' doing.
reset
artifact 1001 coverage-baseline
lookup c12 0
eq "incomplete listing's control, the run in neither listing: nothing is found" false "$(out found)"

# What the latest runs add is held to the filtered listing's own tests.
for shape in "failure|$REPOSITORY" "cancelled|$REPOSITORY" "success|evil/fork"; do
  reset
  latest_run c12 1002 "${shape%%|*}" "${shape#*|}"
  artifact 1002 coverage-baseline
  lookup c12 0
  eq "latest runs: a ${shape%%|*} run of ${shape#*|} is not a baseline" false "$(out found)"
  eq "latest runs: ${shape%%|*} of ${shape#*|}: its artifacts were not even looked at" 0 "$(asked '/actions/runs/1002/')"
done
reset
latest_run c11 1003 success # another commit's
artifact 1003 coverage-baseline
lookup c12 0
eq "latest runs: a run for another commit is not this commit's baseline" false "$(out found)"
lookup c12 1
eq "latest runs' control, depth 1: the same run is the ancestor's baseline" "$(sha c11)" "$(out sha)"
eq "latest runs' control: at distance 1" 1 "$(out distance)"
reset
latest_run c12 1004 success
artifact 1004 coverage-baseline true
lookup c12 0
eq "latest runs: an expired artifact is not a baseline here either" false "$(out found)"

# A run both listings have is looked in once, and what the latest runs add is only the rest.
reset
run c12 1005 success
artifact 1005 coverage-summary
latest_run c12 1005 success
lookup c12 0
eq "overlap: nothing is found" false "$(out found)"
eq "overlap: the run both listings have is looked in once" 1 "$(asked '/actions/runs/1005/artifacts')"
has "overlap: the latest runs add none" "$STDOUT" "The latest runs add 0 such runs; none holds one."

# The shape the glitch has: a subset. The run with no baseline is listed, the one with it is not.
reset
run c12 1006 success
artifact 1006 coverage-summary
latest_run c12 1006 success
latest_run c12 1007 success
artifact 1007 coverage-baseline
lookup c12 0
eq "subset: the run the filtered listing left out is found past the one it kept" 1007 "$(out run-id)"
has "subset: the line counts the one it kept and the one the latest runs added" "$STDOUT" \
  "the listing returned 1 run, 1 successful from this repository; none holds a live 'coverage-baseline'. The latest runs add 1 such run; run 1007 holds one."

# The latest runs are fetched once for the whole walk, and serve every candidate.
reset
latest_run c10 1008 success
artifact 1008 coverage-baseline
lookup c12 10
eq "walk: a baseline only the latest runs have, 2 commits back, is found" "$(sha c10)" "$(out sha)"
eq "walk: the latest runs were fetched once, for 3 candidates" 1 "$(asked 'runs?per_page=100')"
eq "walk: 3 candidates, 3 lines" 3 "$(grep -c '^Candidate ' <<<"$STDOUT")"
has "walk: the line of the first, with no baseline from either listing" "$STDOUT" \
  "Candidate $(short c12) (0 back): the listing returned 0 runs, 0 successful from this repository; none holds a live 'coverage-baseline'. The latest runs add 0 such runs; none holds one."
has "walk: the line of the one that had it" "$STDOUT" \
  "Candidate $(short c10) (2 back): the listing returned 0 runs, 0 successful from this repository; none holds a live 'coverage-baseline'. The latest runs add 1 such run; run 1008 holds one."

# The filtered listing's answer wins when it has one: the latest runs are not asked.
reset
baseline_at c12 1009
latest_run c12 1010 success
artifact 1010 coverage-baseline
lookup c12 0
eq "precedence: the filtered listing's run is the one used" 1009 "$(out run-id)"
eq "precedence: the latest runs were not fetched" 0 "$(asked 'runs?per_page=100')"

# The latest runs failing is not the lookup's failure: the filtered answer stands.
reset
baseline_at c11 1011
fail_with runs-latest 500 '{"message":"stub failure"}'
lookup c12 10
eq "latest runs failing: the script succeeds" 0 "$STATUS"
eq "latest runs failing: the filtered listing's baseline is still found" "$(sha c11)" "$(out sha)"
eq "latest runs failing: three attempts, once for the walk" 3 "$(asked 'runs?per_page=100')"
has "latest runs failing: the line says why they were not used" "$STDOUT" \
  "Candidate $(short c12) (0 back): the listing returned 0 runs, 0 successful from this repository; none holds a live 'coverage-baseline'. The latest runs could not be listed (HTTP 500), so only the filtered listing was used."
lacks "latest runs failing: not an error" "$STDOUT" "::error::"
lacks "latest runs failing: and not a warning, since the answer was not changed" "$STDOUT" "::warning::"
reset
baseline_at c11 1011
lookup c12 10
eq "latest runs failing's control, healthy: the same baseline" "$(sha c11)" "$(out sha)"
eq "latest runs failing's control: fetched once" 1 "$(asked 'runs?per_page=100')"

reset
latest_run c12 1012 success
artifact 1012 coverage-baseline
sequence runs-latest 502 200
lookup c12 0
eq "latest runs: a 502 is tried again, and the run is found" 1012 "$(out run-id)"
eq "latest runs: the 502, the retry" 2 "$(asked 'runs?per_page=100')"

reset
latest_run c12 1013 success
artifact 1013 coverage-baseline
fail_with runs-latest 200 '{"message":"not a list"}'
lookup c12 0
eq "latest runs: an answer that is not a list is not used" false "$(out found)"
eq "latest runs: and it is not an error" 0 "$STATUS"
has "latest runs: the line says what it was" "$STDOUT" "The latest runs could not be listed (the answer was not a list of runs)"

# The first request is still the filtered one, so a permission or an outage still fails there.
reset
baseline_at c12 1014
fail_with "runs-$(sha c12)" 403 '{"message":"Resource not accessible by integration"}'
fail_with runs-latest 403 '{"message":"Resource not accessible by integration"}'
lookup c12 10
eq "the first request is the filtered one: its failure is still the error" 1 "$STATUS"
eq "the first request: nothing else was asked after it" 1 "$(requests)"

# --- what each candidate logs --------------------------------------------------------------------

reset
run c12 1015 failure
artifact 1015 coverage-baseline
run c12 1016 success
artifact 1016 coverage-summary
run c12 1017 success evil/fork
lookup c12 0
eq "the line counts what the listing returned and how many of those count" 1 \
  "$(grep -c "Candidate $(short c12) (0 back): the listing returned 3 runs, 1 successful from this repository; none holds a live 'coverage-baseline'\." <<<"$STDOUT")"
reset
lookup c12 2
eq "a miss: one line per candidate" 3 "$(grep -c '^Candidate ' <<<"$STDOUT")"
has "a miss: the first is the merge-base" "$STDOUT" "Candidate $(short c12) (0 back):"
has "a miss: the last is two back" "$STDOUT" "Candidate $(short c10) (2 back):"
has "a miss: the final warning is as it was" "$STDOUT" "or the 2 ancestors checked before it"

# --- the latest runs can never fail the lookup, only add to it (review of #57) --------------------

# A run only the latest runs gave, whose artifacts cannot be listed: a miss for that run, the walk
# goes on. Before this, `api_failed` made it an error at the merge-base, which the same failure on
# a run the filtered listing gave still is (the contrast below).
reset
latest_run c12 1101 success
artifact 1101 coverage-baseline
baseline_at c11 1102
fail_with artifacts-1101 500 '{"message":"stub failure"}'
lookup c12 10
eq "an added run's artifacts failing: the script succeeds" 0 "$STATUS"
eq "an added run's artifacts failing: the walk goes on to the ancestor's baseline" "$(sha c11)" "$(out sha)"
lacks "an added run's artifacts failing: not an error" "$STDOUT" "::error::"
has "an added run's artifacts failing: the line says which run, and why" "$STDOUT" \
  "The latest runs add 1 such run; run 1101 could not be looked in (HTTP 500: stub failure); none holds one."
reset
latest_run c12 1101 success
artifact 1101 coverage-baseline
baseline_at c11 1102
lookup c12 10
eq "an added run's control, its artifacts listed: the merge-base's own run is found" 1101 "$(out run-id)"
reset
run c12 1101 success
artifact 1101 coverage-baseline
baseline_at c11 1102
fail_with artifacts-1101 500 '{"message":"stub failure"}'
lookup c12 10
eq "contrast: the same failure on a run the filtered listing gave is still the error" 1 "$STATUS"
has "contrast: ... and the line of what had been read so far is logged before it" "$STDOUT" \
  "Candidate $(short c12) (0 back): the listing returned 1 run, 1 successful from this repository; stopped at run 1101: its artifacts could not be listed."

reset
latest_run c12 1109 success
artifact 1109 coverage-baseline
baseline_at c11 1110
fail_with artifacts-1109 200 'this is not json'
lookup c12 10
eq "an added run's artifacts that are not JSON: the script succeeds" 0 "$STATUS"
eq "an added run's artifacts that are not JSON: the walk goes on to the ancestor" "$(sha c11)" "$(out sha)"
has "an added run's artifacts that are not JSON: the line says so" "$STDOUT" "run 1109 could not be looked in (the answer was not JSON)"
reset
run c12 1109 success
artifact 1109 coverage-baseline
baseline_at c11 1110
fail_with artifacts-1109 200 'this is not json'
lookup c12 10
eq "contrast: artifacts that are not JSON for a run the filtered listing gave are still the error" 1 "$STATUS"

# Answers for the latest runs that are not a list of runs, or that hold one this cannot read: they
# are not used, and the lookup is as it was without them.
reset
baseline_at c11 1103
fail_with runs-latest 200 '{"workflow_runs":[1]}'
lookup c12 10
eq "latest runs that are not objects: the script succeeds" 0 "$STATUS"
eq "latest runs that are not objects: the filtered listing's baseline is found" "$(sha c11)" "$(out sha)"
lacks "latest runs that are not objects: not an error" "$STDOUT" "::error::"
has "latest runs that are not objects: the line says they were not used" "$STDOUT" \
  "The latest runs could not be listed (the answer was not a list of runs)"
# A run of this commit whose head_repository is a string: the list is of objects, and the one
# that matters cannot be read, which jq says only when it reaches it.
reset
baseline_at c11 1103
fail_with runs-latest 200 "{\"workflow_runs\":[{\"id\":5,\"head_sha\":\"$(sha c12)\",\"conclusion\":\"success\",\"head_repository\":\"acme/widgets\"}]}"
lookup c12 10
eq "a run of the commit with an unreadable repository: the script succeeds" 0 "$STATUS"
eq "a run of the commit with an unreadable repository: the filtered listing's baseline is found" "$(sha c11)" "$(out sha)"
lacks "a run of the commit with an unreadable repository: not an error" "$STDOUT" "::error::"
has "a run of the commit with an unreadable repository: the line says so" "$STDOUT" \
  "The latest runs could not be read (a run in the answer has an unexpected shape), so only the filtered listing was used."
lacks "a run of the commit with an unreadable repository: and nothing from jq reached the log" "$STDOUT" "jq: error"

# Two runs both listings have: each is looked in once (a `known` list of one id would pass the
# single-run overlap case above).
reset
run c12 1104 success
artifact 1104 coverage-summary
run c12 1105 success
artifact 1105 coverage-summary
latest_run c12 1104 success
latest_run c12 1105 success
lookup c12 0
eq "overlap of two: nothing is found" false "$(out found)"
eq "overlap of two: the first is looked in once" 1 "$(asked '/actions/runs/1104/artifacts')"
eq "overlap of two: the second is looked in once" 1 "$(asked '/actions/runs/1105/artifacts')"

# The workflow name is encoded in the request for the latest runs as in the others.
reset
lookup c12 0 "BASELINE_WORKFLOW=my flow.yml"
eq "a workflow name with a space: the filtered request encodes it" 1 "$(asked 'workflows/my%20flow.yml/runs?head_sha=')"
eq "a workflow name with a space: so does the request for the latest runs" 1 "$(asked 'workflows/my%20flow.yml/runs?per_page=100')"

# Controls for the finds above that had none of their own: the same baseline in the filtered
# listing is found, and nothing is asked of the latest runs when the first candidate has it.
reset
baseline_at c10 1106
lookup c12 10
eq "walk's control: the same baseline 2 back, in the filtered listing, is found" "$(sha c10)" "$(out sha)"
eq "walk's control: the latest runs were still asked, once, by the candidates before it" 1 "$(asked 'runs?per_page=100')"
reset
run c12 1107 success
artifact 1107 coverage-summary
run c12 1108 success
artifact 1108 coverage-baseline
latest_run c12 1107 success
latest_run c12 1108 success
lookup c12 0
eq "subset's control, both runs in the filtered listing: the baseline is found" 1108 "$(out run-id)"
eq "subset's control: the latest runs were not asked" 0 "$(asked 'runs?per_page=100')"

summary
