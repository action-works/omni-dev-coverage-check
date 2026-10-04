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

# lacks <name> <text> <fragment>
lacks() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected '$3' in: $2"; fi
}

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
    sha="${url#*head_sha=}"
    key="runs-${sha%%&*}"
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
  jq -cn --argjson id "$2" --arg c "$3" --arg r "${4:-$REPOSITORY}" \
    '{id: $id, conclusion: $c, status: "completed", head_repository: {full_name: $r}}' \
    >>"$FAKE/runs-$(sha "$1").list"
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
eq "ancestor: it stopped at the first one found (3 runs requests, 1 artifacts request)" 4 "$(requests)"

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
eq "depth 0: it asked about the merge-base only" 1 "$(requests)"
has "depth 0: the warning names the commit" "$STDOUT" "::warning::No baseline 'coverage-baseline' was published by workflow 'ci.yml' for $(sha c12 | cut -c1-7). Continuing without one."
lookup c12 1
eq "depth 0's control, depth 1: the same baseline is found" true "$(out found)"

reset
baseline_at c9 106 # three commits before c12
lookup c12 2
eq "depth 2: a baseline 3 commits back is out of reach" false "$(out found)"
eq "depth 2: it tried the merge-base and 2 ancestors" 3 "$(asked '/actions/workflows/')"
has "depth 2: the warning says how far it looked" "$STDOUT" "for $(sha c12 | cut -c1-7) or the 2 ancestors checked before it"
lookup c12 3
eq "depth 3, the control: the baseline 3 commits back is found" true "$(out found)"
eq "depth 3: distance 3" 3 "$(out distance)"

reset
lookup c12 010
eq "a leading zero is decimal: depth 010 tries 11 commits, not 8" 11 "$(asked '/actions/workflows/')"
reset
lookup c12 ''
eq "an empty depth is 0" 1 "$(requests)"

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
eq "a short history: it tried each of the 3 commits and no more" 3 "$(asked '/actions/workflows/')"
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

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
