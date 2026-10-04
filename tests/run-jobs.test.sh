#!/usr/bin/env bash
# Tests for tests/run-jobs.sh, which lists the jobs of the run for a step that reads them
# all (#89). Plain bash, no framework:
#   tests/run-jobs.test.sh
# Exits non-zero if any case fails.
#
# `gh` is replaced by a fake on PATH that serves the jobs list from a directory, one page
# per file (the real `gh api --paginate` prints the pages one after another), and can
# answer the way the API did on re-runs (#69) or the way a short list would look. A fake
# `sleep` records its argument and does not wait. The last cases read integration.yml and
# test.yml: a script that is right does nothing if the step does not call it.

# The `${{ ... }}` expressions and shell lines matched below are literal text read out of
# the workflow, never meant to expand.
# shellcheck disable=SC2016
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
SCRIPT="$DIR/run-jobs.sh"
WORKFLOW="$ROOT/.github/workflows/integration.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# fresh: a directory with the fake gh and sleep, and no jobs. Prints its path.
fresh() {
  local dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$dir/bin"
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake `gh api --paginate <jobs of the run>`. It counts its reads in $FAKE_DIR/reads.
# FAKE_SEQ="fail html nojobs empty short ok ..." scripts read 1, 2, 3 ... one by one (reads
# past the end are ok):
#   fail    502, with the JSON body gh prints
#   fail2   a failure whose message is two lines
#   html    200 with an HTML page
#   nojobs  200 with JSON that has no `jobs` (a rate-limit answer)
#   empty   200 with a list that has no jobs
#   short   $FAKE_DIR/short-*.json, whatever the case put there
#   ok      $FAKE_DIR/page-*.json, one file per page
[ "$1" = api ] || { echo "fake gh: unexpected: $*" >&2; exit 2; }
shift
[ "$1" != --paginate ] || shift
case "$1" in
  "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=latest&per_page=100") ;;
  *) echo "fake gh: unexpected path: $1" >&2; exit 2 ;;
esac
n=$(($(cat "$FAKE_DIR/reads" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/reads"
read -r -a seq <<<"${FAKE_SEQ:-}"
case "${seq[$((n - 1))]:-ok}" in
  fail)
    echo "gh: Server Error (HTTP 502)" >&2
    echo '{"message":"Server Error"}'
    exit 1
    ;;
  fail2)
    printf 'gh: first line of the failure\nsecond line of the failure\n' >&2
    exit 1
    ;;
  html) echo "<html><body>502 Bad Gateway</body></html>" ;;
  nojobs) echo '{"message":"API rate limit exceeded"}' ;;
  empty) echo '{"total_count":0,"jobs":[]}' ;;
  short) cat "$FAKE_DIR"/short-*.json ;;
  *) cat "$FAKE_DIR"/page-*.json ;;
esac
EOF
  cat >"$dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/sleeps"
EOF
  chmod +x "$dir/bin/gh" "$dir/bin/sleep"
  echo "$dir"
}

# page <dir> <file> <total_count|-> <id:name>...: writes one page of the list. `-` leaves
# total_count out. Every job gets the fields the API has and the script drops.
page() {
  local dir=$1 file=$2 total=$3 jobs="" spec
  shift 3
  for spec in "$@"; do
    jobs+="${jobs:+,}{\"id\":${spec%%:*},\"name\":\"${spec#*:}\",\"status\":\"completed\",\"conclusion\":\"success\",\"runner_name\":\"GitHub Actions 7\"}"
  done
  if [ "$total" = - ]; then
    printf '{"jobs":[%s]}' "$jobs" >"$dir/$file"
  else
    printf '{"total_count":%s,"jobs":[%s]}' "$total" "$jobs" >"$dir/$file"
  fi
}

# run_jobs <dir> [VAR=value...]: runs the script, with stdout in $OUT, stderr in $ERR and
# the status in $STATUS. JOB_LOG_DELAY is 7 so that the fake sleep's record is readable.
run_jobs() {
  local dir=$1
  shift
  OUT="$(env -i PATH="$dir/bin:$PATH" FAKE_DIR="$dir" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 \
    JOB_LOG_DELAY=7 "$@" bash "$SCRIPT" 2>"$dir/stderr")"
  STATUS=$?
  ERR="$(cat "$dir/stderr")"
  READS="$(cat "$dir/reads" 2>/dev/null || echo 0)"
  SLEEPS="$(cat "$dir/sleeps" 2>/dev/null || true)"
}

THREE='[{"id":1,"name":"Alpha","status":"completed","conclusion":"success"},{"id":2,"name":"Beta (x)","status":"completed","conclusion":"success"},{"id":3,"name":"Gamma","status":"completed","conclusion":"success"}]'

# --- a complete list -----------------------------------------------------------------

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d"
eq "a complete list: exits 0" 0 "$STATUS"
eq "  and prints the jobs as one compact array, with id, name, status and conclusion only" "$THREE" "$OUT"
eq "  and asks once" 1 "$READS"
eq "  and does not wait" "" "$SLEEPS"
eq "  and says nothing on stderr" "" "$ERR"

# The pages of a long run come back one after another and are joined.
d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)'
page "$d" page-2.json 3 3:Gamma
run_jobs "$d"
eq "two pages: exits 0" 0 "$STATUS"
eq "  and joins them in order" "$THREE" "$OUT"

# A job that is still running has no conclusion; it is in the list, with null.
d=$(fresh)
printf '{"total_count":1,"jobs":[{"id":9,"name":"Running","status":"in_progress","conclusion":null}]}' >"$d/page-1.json"
run_jobs "$d"
eq "a job still running: it is listed, with a null conclusion" \
  '[{"id":9,"name":"Running","status":"in_progress","conclusion":null}]' "$OUT"

# The count is only checked when the API gives one.
d=$(fresh)
page "$d" page-1.json - 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d"
eq "no total_count: the list is taken as it is" "$THREE" "$OUT"

# --- what it looks at again ----------------------------------------------------------

# Each shape that has been seen, or could be, then a good list: the run succeeds on the
# second look, after one wait of the delay.
while IFS='|' read -r label seq; do
  d=$(fresh)
  page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
  page "$d" short-1.json 5 1:Alpha '2:Beta (x)' 3:Gamma
  run_jobs "$d" "FAKE_SEQ=$seq" JOB_LOG_ATTEMPTS=3
  eq "$label, then a good list: exits 0" 0 "$STATUS"
  eq "  and prints that list" "$THREE" "$OUT"
  eq "  and asked twice" 2 "$READS"
  eq "  and waited the delay once" "7" "$SLEEPS"
  has "  and says why it looked again" "$ERR" "could not be listed (attempt 1 of 3)"
done <<'EOF'
a 502|fail ok
a body that is not JSON|html ok
JSON with no jobs (a rate limit)|nojobs ok
a list with no job|empty ok
a list short of the API's own count|short ok
EOF

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
page "$d" short-1.json 5 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" "FAKE_SEQ=fail html nojobs empty short ok" JOB_LOG_ATTEMPTS=6
eq "every kind in a row, then a good list: exits 0 on the sixth look" 0 "$STATUS"
eq "  asked six times" 6 "$READS"
eq "  waited between the looks, and not after the last" "7
7
7
7
7" "$SLEEPS"
has "  the 502 is named" "$ERR" "(attempt 1 of 6): gh: Server Error (HTTP 502)"
has "  the HTML is named by what jq said" "$ERR" "(attempt 2 of 6): jq:"
has "  the answer with no jobs is named" "$ERR" "(attempt 3 of 6): jq: error"
has "  ... and says what is missing" "$ERR" "the answer holds no list of jobs"
has "  the empty list is named" "$ERR" "(attempt 4 of 6): the list holds no job, and this job is in the run"
has "  the short list is named, with both numbers" "$ERR" "(attempt 5 of 6): the list holds 3 jobs and the API counts 5"

# --- RUN_JOBS_MIN: the lower bound a caller knows -----------------------------------

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" RUN_JOBS_MIN=3
eq "a list exactly as long as the minimum: exits 0" 0 "$STATUS"
eq "  and asked once" 1 "$READS"

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
page "$d" short-1.json 2 1:Alpha '2:Beta (x)'
run_jobs "$d" RUN_JOBS_MIN=3 FAKE_SEQ="short ok" JOB_LOG_ATTEMPTS=3
eq "a list shorter than the minimum, consistent with the API's count: it is looked at again" 0 "$STATUS"
eq "  and the second, long enough, list is the answer" "$THREE" "$OUT"
eq "  asked twice" 2 "$READS"
has "  and says it was short of the minimum" "$ERR" "the list holds 2 jobs and the run has at least 3"

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" RUN_JOBS_MIN=4 JOB_LOG_ATTEMPTS=3
eq "a list that stays shorter than the minimum: exits 1" 1 "$STATUS"
eq "  after every attempt" 3 "$READS"
eq "  printing nothing on stdout" "" "$OUT"
has "  with the error naming the run and the attempts" "$ERR" "::error::could not list the jobs of run 42 after 3 attempts: the list holds 3 jobs and the run has at least 4"

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" RUN_JOBS_MIN=0
eq "a minimum of 0: no bound" 0 "$STATUS"
run_jobs "$d"
eq "no minimum set: no bound" 0 "$STATUS"

for bad in x -1 1.5 " 3" 3x ""; do
  d=$(fresh)
  page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
  run_jobs "$d" "RUN_JOBS_MIN=$bad"
  eq "RUN_JOBS_MIN='$bad' is refused: exits 2" 2 "$STATUS"
  has "  and says what it needs" "$ERR" "::error::RUN_JOBS_MIN must be a whole number"
  eq "  before it asks the API anything" 0 "$READS"
done

# --- giving up -----------------------------------------------------------------------

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" "FAKE_SEQ=fail fail fail fail fail fail fail" JOB_LOG_ATTEMPTS=6
eq "a call that fails every time: exits 1" 1 "$STATUS"
eq "  after six looks by default" 6 "$READS"
eq "  printing nothing on stdout" "" "$OUT"
eq "  waiting five times, not after the last" "7
7
7
7
7" "$SLEEPS"
has "  and the error names the run, the attempts and the 502" "$ERR" \
  "::error::could not list the jobs of run 42 after 6 attempts: gh: Server Error (HTTP 502)"

d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" "FAKE_SEQ=fail fail fail fail fail fail"
eq "six is the default number of looks" 6 "$READS"

# The message that ends it is the last look's, and the earlier ones are above it.
d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" "FAKE_SEQ=empty fail" JOB_LOG_ATTEMPTS=2
eq "an empty list and then a 502: exits 1" 1 "$STATUS"
has "  the error carries the last look's reason" "$ERR" "after 2 attempts: gh: Server Error (HTTP 502)"
has "  and the first look's is in the log above it" "$ERR" "(attempt 1 of 2): the list holds no job"

# More jobs than the API counts is as wrong as fewer, and is looked at again.
d=$(fresh)
page "$d" page-1.json 3 1:Alpha '2:Beta (x)' 3:Gamma
page "$d" short-1.json 2 1:Alpha '2:Beta (x)' 3:Gamma
run_jobs "$d" "FAKE_SEQ=short ok" JOB_LOG_ATTEMPTS=3
eq "a list longer than the API's count, then a good one: exits 0 on the second look" 0 "$STATUS"
eq "  asked twice" 2 "$READS"
has "  and says the numbers disagree" "$ERR" "the list holds 3 jobs and the API counts 2"

d=$(fresh)
page "$d" short-1.json 5 1:Alpha
run_jobs "$d" "FAKE_SEQ=short short" JOB_LOG_ATTEMPTS=2
eq "a short list that stays short: exits 1" 1 "$STATUS"
has "  and says so" "$ERR" "after 2 attempts: the list holds 1 jobs and the API counts 5"

d=$(fresh)
run_jobs "$d" "FAKE_SEQ=html html" JOB_LOG_ATTEMPTS=2
eq "an HTML body that stays one: exits 1" 1 "$STATUS"
eq "  printing nothing on stdout" "" "$OUT"

# A failure whose message has two lines is one line in the annotation, and in the log.
d=$(fresh)
run_jobs "$d" "FAKE_SEQ=fail2 fail2" JOB_LOG_ATTEMPTS=2
eq "a two-line failure: exits 1" 1 "$STATUS"
has "  the error is one line" "$ERR" "::error::could not list the jobs of run 42 after 2 attempts: gh: first line of the failure second line of the failure"
eq "  and so is each look's line" 2 "$(grep -c 'could not be listed (attempt' <<<"$ERR")"

# One attempt: it asks once and does not wait.
d=$(fresh)
run_jobs "$d" "FAKE_SEQ=fail" JOB_LOG_ATTEMPTS=1
eq "one attempt: exits 1 after one look" 1 "$STATUS"
eq "  asked once" 1 "$READS"
eq "  and did not wait" "" "$SLEEPS"

# --- usage ---------------------------------------------------------------------------

d=$(fresh)
OUT="$(env -i PATH="$d/bin:$PATH" FAKE_DIR="$d" GITHUB_REPOSITORY=o/r bash "$SCRIPT" 2>&1)"
eq "no run id: exits non-zero, naming it" 1 "$?"
has "  and names the variable" "$OUT" "GITHUB_RUN_ID is not set"
OUT="$(env -i PATH="$d/bin:$PATH" FAKE_DIR="$d" GITHUB_RUN_ID=42 bash "$SCRIPT" 2>&1)"
has "no repository: names the variable" "$OUT" "GITHUB_REPOSITORY is not set"

# --- wiring: the step uses it ---------------------------------------------------------

STEP="$(awk '
  /^      - name: Assert the deprecation warnings$/ { printing = 1; print; next }
  printing && /^  [^ ]/ { exit }
  printing { print }
' "$WORKFLOW")"
pass "integration.yml: found the deprecation step" test -n "$STEP"
has "the step reads what it needs through env" "$STEP" '          NEEDS: ${{ toJSON(needs) }}'
has "the step holds the list to the jobs it needs, and itself" "$STEP" \
  "min=\"\$(jq 'length + 1' <<<\"\$NEEDS\")\""
has "the step lists the jobs with run-jobs.sh, given that minimum" "$STEP" \
  'jobs="$(RUN_JOBS_MIN="$min" bash tests/run-jobs.sh)"'
lacks "the step no longer lists the jobs with a bare gh call" "$STEP" "gh api --paginate"
has "a failure to list ends the step red" "$STEP" "            else
              status=1
            fi
          fi
          exit \"\$status\""

TEST_WORKFLOW="$ROOT/.github/workflows/test.yml"
has "test.yml runs this test" "$(<"$TEST_WORKFLOW")" "        run: bash tests/run-jobs.test.sh"

summary
