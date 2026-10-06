#!/usr/bin/env bash
# Tests for tests/job-errors.sh, tests/job-deprecations.sh and tests/job-warnings.sh, which
# pick their lines out of the log that tests/job-log.sh reads. Plain bash, no framework:
#   tests/job-errors.test.sh
# Exits non-zero if any case fails.
#
# `gh` is replaced by a fake on PATH that serves a jobs list and per-job logs from
# a directory, so the tests need no network. The log lines are the shape of a
# real runner log, including the colour-coded echo of a step's script, which holds
# the same text as the message it would print.

# The `bash -c` snippets below are single-quoted on purpose: they expand in the
# child shell, with the values passed as arguments.
# shellcheck disable=SC2016
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/job-errors.sh"
DEPRECATIONS="$DIR/job-deprecations.sh"
WARNINGS="$DIR/job-warnings.sh"
ROOT="$(cd "$DIR/.." && pwd)"
LOG="$DIR/job-log.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# A fresh directory per case, with the fake gh and an empty set of jobs.
fresh() {
  local dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$dir/bin" "$dir/logs"
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake `gh api`: serves $FAKE_DIR/jobs.json and $FAKE_DIR/logs/<job id>, and fails
# the first $FAKE_FAIL_FIRST log reads the way a log that is not there yet does.
# It counts its job-list reads in $FAKE_DIR/jobs-reads and can misbehave on the first
# few, the way the API did on re-runs (#69): FAKE_JOBS_FAIL_FIRST=N answers 502,
# FAKE_JOBS_GARBAGE_FIRST=N answers 200 with an HTML page, FAKE_JOBS_EMPTY_FIRST=N
# answers 200 with a list that has no jobs. FAKE_JOBS_FAIL fails every read.
# FAKE_JOBS_SEQ="fail html empty nojobs ok ..." scripts read 1, 2, 3 ... one by one
# (nojobs is a 200 whose JSON has no `jobs`; reads past the end are ok), for sequences
# the counts above cannot say, such as an empty list and then a 502.
# It behaves like gh 2.97 and later, which refuse to print a response holding
# terminal escape sequences unless given --allow-escape-sequences. With
# FAKE_GH_OLD set it behaves like an older gh, which has no such flag.
[ "$1" = api ] || { echo "fake gh: unexpected: $*" >&2; exit 2; }
shift
allow_escapes=false
while [[ ${1:-} == --* ]]; do
  case "$1" in
    --paginate) ;; # the real gh joins the pages; one page is all this serves
    --allow-escape-sequences)
      if [ -n "${FAKE_GH_OLD:-}" ]; then
        echo "unknown flag: --allow-escape-sequences" >&2
        exit 1
      fi
      allow_escapes=true
      ;;
    --help)
      echo "Flags:"
      [ -n "${FAKE_GH_OLD:-}" ] || echo "      --allow-escape-sequences   Allow printing content containing terminal escape sequences"
      # A help longer than a pipe buffer, written by this process itself, so a
      # reader that stops at the first match (grep -q in a pipe) leaves it to die
      # of SIGPIPE, as a real gh can.
      for ((i = 0; i < 20000; i++)); do echo "more of the help text"; done
      exit 0
      ;;
    *)
      echo "fake gh: unexpected flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done
case "$1" in
  "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs?filter=latest&per_page=100")
    n=$(($(cat "$FAKE_DIR/jobs-reads" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/jobs-reads"
    if [ -n "${FAKE_JOBS_FAIL:-}" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      echo '{"message":"Not Found"}'
      exit 1
    fi
    if [ -n "${FAKE_JOBS_SEQ:-}" ]; then
      read -r -a seq <<<"$FAKE_JOBS_SEQ"
      case "${seq[$((n - 1))]:-ok}" in
        fail)
          echo "gh: Server Error (HTTP 502)" >&2
          echo '{"message":"Server Error"}'
          exit 1
          ;;
        html)
          echo "<html><body>502 Bad Gateway</body></html>"
          exit 0
          ;;
        empty)
          echo '{"jobs":[]}'
          exit 0
          ;;
        nojobs)
          echo '{"message":"API rate limit exceeded"}'
          exit 0
          ;;
      esac
    fi
    if [ "$n" -le "${FAKE_JOBS_FAIL_FIRST:-0}" ]; then
      echo "gh: Server Error (HTTP 502)" >&2
      echo '{"message":"Server Error"}'
      exit 1
    fi
    if [ "$n" -le "${FAKE_JOBS_GARBAGE_FIRST:-0}" ]; then
      echo "<html><body>502 Bad Gateway</body></html>"
      exit 0
    fi
    if [ "$n" -le "${FAKE_JOBS_EMPTY_FIRST:-0}" ]; then
      echo '{"jobs":[]}'
      exit 0
    fi
    cat "$FAKE_DIR/jobs.json"
    ;;
  "repos/$GITHUB_REPOSITORY/actions/jobs/"*/logs)
    id="${1%/logs}"
    id="${id##*/}"
    n=$(($(cat "$FAKE_DIR/log-reads" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE_DIR/log-reads"
    if [ "$n" -le "${FAKE_FAIL_FIRST:-0}" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    if [ -z "${FAKE_GH_OLD:-}" ] && [ "$allow_escapes" != true ] && grep -q $'\033' "$FAKE_DIR/logs/$id"; then
      echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2
      exit 1
    fi
    cat "$FAKE_DIR/logs/$id"
    ;;
  *)
    echo "fake gh: unexpected path: $1" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  echo '{"jobs":[]}' >"$dir/jobs.json"
  echo "$dir"
}

# add_job <dir> <id> <name>: adds a job to the run, with an empty log.
add_job() {
  local dir=$1 id=$2 name=$3
  jq -c --argjson id "$id" --arg name "$name" '.jobs += [{id: $id, name: $name}]' "$dir/jobs.json" >"$dir/jobs.tmp"
  mv "$dir/jobs.tmp" "$dir/jobs.json"
  : >"$dir/logs/$id"
}

# run_script <script> <dir> <job name> [VAR=value...]: runs a script, capturing
# stdout in $OUT, stderr in $ERR and the exit status in $STATUS.
run_script() {
  local script=$1 dir=$2 name=$3
  shift 3
  OUT="$(env -i PATH="$dir/bin:$PATH" FAKE_DIR="$dir" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 \
    JOB_LOG_DELAY=0 "$@" bash "$script" "$name" 2>"$dir/stderr")"
  STATUS=$?
  ERR="$(cat "$dir/stderr")"
}

# run_errors, run_deprecations <dir> <job name> [VAR=value...]
run_errors() {
  local dir=$1 name=$2
  shift 2
  run_script "$SCRIPT" "$dir" "$name" "$@"
}

run_deprecations() {
  local dir=$1 name=$2
  shift 2
  run_script "$DEPRECATIONS" "$dir" "$name" "$@"
}

run_warnings() {
  local dir=$1 name=$2
  shift 2
  run_script "$WARNINGS" "$dir" "$name" "$@"
}

# The log of a job that ran the guard and the shard combine, and failed them
# both: what a real log holds, in order. The first line has the byte-order mark.
LOG_TWO_ERRORS="$(printf '\357\273\277%s\n' \
  "2026-10-03T15:44:19.7678995Z Current runner version: '2.329.0'")
2026-10-03T15:44:33.4843361Z $(printf '\033[36;1m')if ! grep -q -- '--fail-under-lines' <<<\"\$help\"; then$(printf '\033[0m')
2026-10-03T15:44:33.4843944Z $(printf '\033[36;1m')  echo \"::error::\$(patchcov --version) has no 'coverage diff --fail-under-lines', which thin mode uses\"$(printf '\033[0m')
2026-10-03T15:44:33.4891094Z ##[endgroup]
2026-10-03T15:44:33.5179483Z ##[error]shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
2026-10-03T15:44:33.5180225Z ##[error]Process completed with exit code 1."

# --- reading the messages -----------------------------------------------------

d=$(fresh)
add_job "$d" 101 'Thin mode (patchcov latest)'
printf '%s\n' "$LOG_TWO_ERRORS" >"$d/logs/101"
run_errors "$d" 'Thin mode (patchcov latest)'
pass "reads a job's log" test "$STATUS" -eq 0
eq "prints each error message without its timestamp or marker" \
  "shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
Process completed with exit code 1." "$OUT"
pass "does not return the echoed script, which holds the same message text" \
  bash -c '! grep -qF "has no" <<<"$1"' _ "$OUT"
pass "fixture: the log does echo the message text outside an error line" \
  grep -qF "has no 'coverage diff" "$d/logs/101"

# A gh that refuses escape sequences, like the one on a current runner, must be
# given the flag; an older one has no such flag and must not be.
run_errors "$d" 'Thin mode (patchcov latest)' FAKE_GH_OLD=1
pass "reads the log with a gh that has no --allow-escape-sequences" test "$STATUS" -eq 0
eq "and prints the same messages" \
  "shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
Process completed with exit code 1." "$OUT"
pass "fixture: a current gh does refuse this log without the flag" \
  bash -c '! env -i PATH="$1/bin:$PATH" FAKE_DIR="$1" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 \
    gh api "repos/o/r/actions/jobs/101/logs" >/dev/null 2>&1' _ "$d"

printf '%s\r\n' "2026-10-03T15:44:33.5179483Z ##[error]a message" >"$d/logs/101"
run_errors "$d" 'Thin mode (patchcov latest)'
eq "strips carriage returns" "a message" "$OUT"

printf '%s\n' "2026-10-03T15:44:33.5179483Z echo ##[error]not a runner marker" \
  "2026-10-03T15:44:33.5179483Z ##[group]Run something" >"$d/logs/101"
run_errors "$d" 'Thin mode (patchcov latest)'
eq "a step's own output that merely contains the marker does not count" "" "$OUT"

printf '%s\n' "2026-10-03T15:44:33.5179483Z ##[group]Run something" >"$d/logs/101"
run_errors "$d" 'Thin mode (patchcov latest)'
pass "a log without errors is not a failure" test "$STATUS" -eq 0
eq "a log without errors prints nothing" "" "$OUT"

# --- finding the job ----------------------------------------------------------

d=$(fresh)
add_job "$d" 201 'Thin mode (patchcov 0.1.1)'
add_job "$d" 202 'Thin mode (patchcov latest)'
add_job "$d" 203 'Thin mode (patchcov latest) and more'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 201" >"$d/logs/201"
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 202" >"$d/logs/202"
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 203" >"$d/logs/203"
run_errors "$d" 'Thin mode (patchcov latest)'
eq "picks the job by its exact name" "from 202" "$OUT"

run_errors "$d" 'Thin mode (patchcov 0.4'
pass "a name that only prefixes another is not found" test "$STATUS" -ne 0
pass "a missing job is named in the error" grep -q "0 jobs named 'Thin mode (patchcov 0.4'" <<<"$ERR"

add_job "$d" 204 'Thin mode (patchcov latest)'
run_errors "$d" 'Thin mode (patchcov latest)'
pass "two jobs with one name are ambiguous, not the first" test "$STATUS" -ne 0
pass "an ambiguous name is reported" grep -q "2 jobs named" <<<"$ERR"

run_errors "$d" 'Thin mode (patchcov 0.1.1)' FAKE_JOBS_FAIL=1
pass "a failed jobs call fails the script" test "$STATUS" -ne 0
pass "and is not mistaken for a missing job or an unreadable log" \
  bash -c '! grep -q "jobs named\|could not read the log" <<<"$1"' _ "$ERR"
pass "and shows the API's own error, not a parse error after it" \
  bash -c 'grep -q "Not Found" <<<"$1" && ! grep -q "jq:" <<<"$1"' _ "$ERR"
eq "and prints no messages" "" "$OUT"

# --- the job list may take a few looks (#69) ----------------------------------

# On re-runs of a workflow the list was seen without jobs that were there (a different few
# each time, complete again later), and the API answers 502 now and then. The lookup used
# to fail on the first of either; it is retried as the log read is. A name found twice is
# an ambiguity another look does not change, so that one is not.

# with_job <id> <name>: sets $d to a fresh case with that one job, whose log holds one error.
with_job() {
  d=$(fresh)
  add_job "$d" "$1" "$2"
  printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]found it" >"$d/logs/$1"
}

with_job 601 'Thin mode (patchcov 0.1.1)'
run_errors "$d" 'Thin mode (patchcov 0.1.1)' FAKE_JOBS_EMPTY_FIRST=2 JOB_LOG_ATTEMPTS=6
pass "a list without the job is looked at again" test "$STATUS" -eq 0
eq "and the job is read once it is listed" "found it" "$OUT"
eq "the list was read three times" 3 "$(cat "$d/jobs-reads")"
pass "each look that found nothing says so" \
  grep -q "run 42 lists no job named 'Thin mode (patchcov 0.1.1)' yet (attempt 2 of 6)" <<<"$ERR"

with_job 602 'Job'
run_errors "$d" 'Job' FAKE_JOBS_EMPTY_FIRST=99 JOB_LOG_ATTEMPTS=3
pass "a job that is never listed fails the script" test "$STATUS" -ne 0
eq "after exactly the attempts it was given" 3 "$(cat "$d/jobs-reads")"
pass "and says it has none of that name, and that it kept looking" \
  grep -q "run 42 has 0 jobs named 'Job', not one (after 3 attempts)" <<<"$ERR"
pass "and never went on to read a log" test ! -e "$d/log-reads"
eq "and prints no messages" "" "$OUT"

with_job 603 'Job'
run_errors "$d" 'Job' FAKE_JOBS_FAIL_FIRST=2 JOB_LOG_ATTEMPTS=6
pass "a list call that answers 502 is tried again" test "$STATUS" -eq 0
eq "and the job is read once the call works" "found it" "$OUT"
eq "the call was made three times" 3 "$(cat "$d/jobs-reads")"
pass "each failure shows the API's own error" \
  grep -q "the jobs of run 42 could not be listed (attempt 1 of 6): gh: Server Error (HTTP 502)" <<<"$ERR"

with_job 604 'Job'
run_errors "$d" 'Job' FAKE_JOBS_FAIL_FIRST=99 JOB_LOG_ATTEMPTS=3
pass "a list call that never works fails the script" test "$STATUS" -ne 0
eq "after exactly the attempts it was given" 3 "$(cat "$d/jobs-reads")"
pass "and says the jobs could not be listed, with the API's own words" \
  grep -q "could not list the jobs of run 42 after 3 attempts: gh: Server Error (HTTP 502)" <<<"$ERR"
pass "and is not mistaken for a missing job or an unreadable log" \
  bash -c '! grep -q "jobs named\|could not read the log" <<<"$1"' _ "$ERR"
eq "and prints no messages" "" "$OUT"

# The last attempt counts: two failures and a third try that works.
with_job 605 'Job'
run_errors "$d" 'Job' FAKE_JOBS_FAIL_FIRST=2 JOB_LOG_ATTEMPTS=3
pass "the last attempt is still an attempt" test "$STATUS" -eq 0
eq "and returns what it read" "found it" "$OUT"

# A 502 and then an incomplete list and then the job: each is its own kind of look.
with_job 606 'Job'
run_errors "$d" 'Job' FAKE_JOBS_FAIL_FIRST=1 FAKE_JOBS_EMPTY_FIRST=2 JOB_LOG_ATTEMPTS=6
pass "a failed call, an incomplete list, then the job" test "$STATUS" -eq 0
eq "took three looks" 3 "$(cat "$d/jobs-reads")"

# A gateway's HTML page with a 200 is no list either: it is looked at again, and with
# nothing else to go on the final message carries jq's own error.
with_job 607 'Job'
run_errors "$d" 'Job' FAKE_JOBS_GARBAGE_FIRST=1 JOB_LOG_ATTEMPTS=6
pass "a body that is not JSON is looked at again" test "$STATUS" -eq 0
eq "and the job is read once the list parses" "found it" "$OUT"
eq "that took two looks" 2 "$(cat "$d/jobs-reads")"
pass "the first look says the jobs could not be listed" \
  grep -q "the jobs of run 42 could not be listed (attempt 1 of 6)" <<<"$ERR"
with_job 608 'Job'
run_errors "$d" 'Job' FAKE_JOBS_GARBAGE_FIRST=99 JOB_LOG_ATTEMPTS=2
pass "a body that is never JSON fails the script" test "$STATUS" -ne 0
pass "and says the jobs could not be listed, with jq's own words as the reason" \
  grep -q "could not list the jobs of run 42 after 2 attempts: jq: parse error" <<<"$ERR"
eq "and prints no messages" "" "$OUT"

# Two jobs of one name is not a transient state. One look, then the error.
d=$(fresh)
add_job "$d" 609 'Job'
add_job "$d" 610 'Job'
run_errors "$d" 'Job' JOB_LOG_ATTEMPTS=6
pass "a name found twice fails the script" test "$STATUS" -ne 0
eq "at the first look" 1 "$(cat "$d/jobs-reads")"
pass "as an ambiguity, not as a job that was never listed" \
  bash -c 'grep -q "2 jobs named .Job., not one" <<<"$1" && ! grep -q "attempts)" <<<"$1"' _ "$ERR"

# The wait between looks is the configured delay, and there is none after the last one. It
# is asserted for each kind of look that fails (a 502 is the one that failed in #69), since
# the wait sits in one place and a copy of it in only one branch would leave the others
# retrying at once. The fake `sleep` records its argument and does not wait.
with_job 611 'Job'
cat >"$d/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$FAKE_DIR/sleeps"
EOF
chmod +x "$d/bin/sleep"
# waits_for <label> <VAR=value>: three looks that all fail the same way, a delay of 7.
waits_for() {
  rm -f "$d/sleeps" "$d/jobs-reads"
  run_errors "$d" 'Job' "$2" JOB_LOG_ATTEMPTS=3 JOB_LOG_DELAY=7
  eq "$1: it waits the delay between looks and not after the last: two waits of 7" "7
7" "$(cat "$d/sleeps" 2>/dev/null)"
}
waits_for "a list without the job" FAKE_JOBS_EMPTY_FIRST=99
waits_for "a call that answers 502" FAKE_JOBS_FAIL_FIRST=99
waits_for "a body that is not JSON" FAKE_JOBS_GARBAGE_FIRST=99
waits_for "JSON with no jobs in it" "FAKE_JOBS_SEQ=nojobs nojobs nojobs"

# What ends a run of looks is the LAST look. A list that lacked the job twice and then
# answered 502 reports the 502, not "0 jobs", and the earlier looks are above it in the log;
# the other way round reports the missing job. Without `listed=false` the first would claim
# the job was missing from a list nobody got.
with_job 613 'Job'
run_errors "$d" 'Job' "FAKE_JOBS_SEQ=empty empty fail" JOB_LOG_ATTEMPTS=3
pass "empty list, empty list, then a 502: fails the script" test "$STATUS" -ne 0
pass "it says the jobs could not be listed, with the 502" \
  grep -q "could not list the jobs of run 42 after 3 attempts: gh: Server Error (HTTP 502)" <<<"$ERR"
pass "and not that the job is missing" bash -c '! grep -q "has 0 jobs named" <<<"$1"' _ "$ERR"
pass "the earlier looks are in the log" \
  grep -q "run 42 lists no job named 'Job' yet (attempt 2 of 3)" <<<"$ERR"

with_job 614 'Job'
run_errors "$d" 'Job' "FAKE_JOBS_SEQ=fail html empty" JOB_LOG_ATTEMPTS=3
pass "a 502, an HTML page, then an empty list: fails the script" test "$STATUS" -ne 0
pass "it says the job is missing after three attempts, though one list was read" \
  grep -q "run 42 has 0 jobs named 'Job', not one (after 3 attempts)" <<<"$ERR"
eq "all three looks were made" 3 "$(cat "$d/jobs-reads")"

with_job 615 'Job'
run_errors "$d" 'Job' "FAKE_JOBS_SEQ=empty fail ok" JOB_LOG_ATTEMPTS=3
pass "an empty list, a 502, then the job: found on the last look" test "$STATUS" -eq 0
eq "and read" "found it" "$OUT"

# JSON that parses but has no `jobs` (a rate-limit body that still came with a 200) is a list
# nobody got either: looked at again, and the final message says what jq made of it.
with_job 616 'Job'
run_errors "$d" 'Job' "FAKE_JOBS_SEQ=nojobs ok" JOB_LOG_ATTEMPTS=3
pass "JSON with no jobs in it is looked at again" test "$STATUS" -eq 0
eq "and the job is read once the list is real" "found it" "$OUT"
with_job 617 'Job'
run_errors "$d" 'Job' "FAKE_JOBS_SEQ=nojobs nojobs" JOB_LOG_ATTEMPTS=2
pass "JSON that never has jobs fails the script" test "$STATUS" -ne 0
pass "and says the jobs could not be listed, with jq's words" \
  grep -q "could not list the jobs of run 42 after 2 attempts: jq: error .*Cannot iterate over null" <<<"$ERR"

# --- reading the log may take a few tries -------------------------------------

d=$(fresh)
add_job "$d" 301 'Job'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]late" >"$d/logs/301"
run_errors "$d" 'Job' FAKE_FAIL_FIRST=2 JOB_LOG_ATTEMPTS=6
pass "retries a log that is not readable yet" test "$STATUS" -eq 0
eq "and then returns it" "late" "$OUT"
eq "reading it took three tries" 3 "$(cat "$d/log-reads")"

d=$(fresh)
add_job "$d" 302 'Job'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]never" >"$d/logs/302"
run_errors "$d" 'Job' FAKE_FAIL_FIRST=99 JOB_LOG_ATTEMPTS=3
pass "gives up on a log that never becomes readable" test "$STATUS" -ne 0
eq "after exactly the attempts it was given" 3 "$(cat "$d/log-reads")"
pass "and says which job" grep -q "could not read the log of job 'Job' (302) after 3 attempts" <<<"$ERR"
pass "and why, in gh's own words" grep -q "after 3 attempts: gh: Not Found (HTTP 404)" <<<"$ERR"
eq "and prints no messages" "" "$OUT"

# --- reading the deprecation warnings -----------------------------------------

ESC=$'\033'
WARN_FLAG='warning: --format is deprecated; use -o/--output instead'
WARN_FN='warning: use of deprecated function `old`: use `new`'
WARN_CAPITAL='warning: Deprecated: the --foo spelling is going away'
WARN_UPPER='warning: --old is DEPRECATED and will be removed'
WARN_NOUN='warning: deprecation of --bar: use --baz instead'

# The shape of a real log (the one in #14 held ten of the first line, and every log
# holds the node and runner notices): the echo of a step's script that holds the
# same words as the warning, the warning itself as a program printed it, notices
# that are about the actions' runtime, and warnings that are not deprecations.
deprecation_log() {
  printf '\357\273\277%s\n' "2026-10-04T00:59:19.1Z Current runner version: '2.329.0'"
  printf '%s\n' \
    "2026-10-04T00:59:22.4Z ${ESC}[36;1m# the warning reads: warning: --format is deprecated${ESC}[0m" \
    "2026-10-04T00:59:22.4Z ${ESC}[36;1mecho \"$WARN_FLAG\"${ESC}[0m" \
    '2026-10-04T00:59:22.5Z ##[endgroup]' \
    "2026-10-04T00:59:22.6Z $WARN_FLAG" \
    '2026-10-04T00:59:23.0Z (node:2301) [DEP0040] DeprecationWarning: The `punycode` module is deprecated. Please use a userland alternative instead.' \
    '2026-10-04T00:59:23.1Z ##[warning]Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/cache@v4' \
    '2026-10-04T00:59:23.2Z warning: unused variable: `x`' \
    "2026-10-04T00:59:23.3Z $WARN_FN" \
    '2026-10-04T00:59:23.4Z error: a removed flag is no longer deprecated, it is gone' \
    "2026-10-04T00:59:23.5Z $WARN_CAPITAL" \
    "2026-10-04T00:59:23.6Z $WARN_UPPER" \
    "2026-10-04T00:59:23.7Z $WARN_NOUN"
}

d=$(fresh)
add_job "$d" 401 'Thin mode (patchcov latest)'
deprecation_log >"$d/logs/401"
run_deprecations "$d" 'Thin mode (patchcov latest)'
pass "deprecations: reads a job's log" test "$STATUS" -eq 0
eq "deprecations: prints the warnings a program logged, without their timestamp" \
  "$WARN_FLAG
$WARN_FN
$WARN_CAPITAL
$WARN_UPPER
$WARN_NOUN" "$OUT"
pass "deprecations: not the echoed script, which holds the same words" \
  bash -c '! grep -qF "echo" <<<"$1"' _ "$OUT"
pass "deprecations: not the runner's or node's own notice" \
  bash -c '! grep -qE "Node.js 20|punycode" <<<"$1"' _ "$OUT"
pass "deprecations: not a warning that is not about a deprecation" \
  bash -c '! grep -qF "unused variable" <<<"$1"' _ "$OUT"
pass "fixture: the log does echo the warning's words outside a warning line" \
  grep -qF "echo \"$WARN_FLAG\"" "$d/logs/401"
pass "fixture: the log does hold the runner's and node's deprecation notices" \
  bash -c 'grep -qF "##[warning]Node.js 20 is deprecated" "$1" && grep -qF "DeprecationWarning" "$1"' _ "$d/logs/401"

printf '%s\r\n' "2026-10-04T00:59:22.6Z $WARN_FLAG" >"$d/logs/401"
run_deprecations "$d" 'Thin mode (patchcov latest)'
eq "deprecations: strips carriage returns" "$WARN_FLAG" "$OUT"

printf '%s\n' "2026-10-04T00:59:22.6Z warning: unused variable: \`x\`" >"$d/logs/401"
run_deprecations "$d" 'Thin mode (patchcov latest)'
pass "deprecations: a log without one is not a failure" test "$STATUS" -eq 0
eq "deprecations: a log without one prints nothing" "" "$OUT"

# The plumbing is job-log.sh's, shared with job-errors.sh and tested above for it;
# these show the new script fails the same way, with no warnings printed.
run_deprecations "$d" 'No such job'
pass "deprecations: a missing job fails the script" test "$STATUS" -ne 0
pass "deprecations: and is named" grep -q "0 jobs named 'No such job'" <<<"$ERR"
eq "deprecations: and prints nothing" "" "$OUT"

d=$(fresh)
add_job "$d" 402 'Job'
deprecation_log >"$d/logs/402"
run_deprecations "$d" 'Job' FAKE_FAIL_FIRST=99 JOB_LOG_ATTEMPTS=2
pass "deprecations: a log that is never readable fails the script" test "$STATUS" -ne 0
pass "deprecations: and says so" grep -q "could not read the log of job 'Job' (402) after 2 attempts" <<<"$ERR"
eq "deprecations: and prints nothing" "" "$OUT"

# The job list is read by job-log.sh too, so a list that lacks the job at first, or a call
# that answers 502, is looked at again here as well (#69).
d=$(fresh)
add_job "$d" 403 'Job'
deprecation_log >"$d/logs/403"
run_deprecations "$d" 'Job' FAKE_JOBS_FAIL_FIRST=1 FAKE_JOBS_EMPTY_FIRST=2 JOB_LOG_ATTEMPTS=6
pass "deprecations: a failed call and an incomplete list are looked at again" test "$STATUS" -eq 0
eq "deprecations: after three looks, the warnings are read" "$WARN_FLAG
$WARN_FN
$WARN_CAPITAL
$WARN_UPPER
$WARN_NOUN" "$OUT"
eq "deprecations: the list was read three times" 3 "$(cat "$d/jobs-reads")"

# --- reading the warnings ------------------------------------------------------

# The warnings the resolve step logged in the `latest-redirect` job of PR #53 (job
# 111359543489), as the runner printed them, with the other warnings that log holds: the
# runner's own Node.js notice and another step's. The text of the fallback's is the shape
# the assertion in `failure-messages` reads (#61). Since #62 a token the API refuses logs only
# a warning of that kind, worded "refused the request (HTTP 401) and was not asked again", and
# no `Attempt n/3` lines, which would claim retries that did not happen; this log is the older
# shape, which the reader reads just the same. The pairing below is with the current text.
W_ATTEMPT1='Attempt 1/3: could not resolve latest patchcov version (API: Bad credentials)'
W_ATTEMPT2='Attempt 2/3: could not resolve latest patchcov version (API: Bad credentials)'
W_ATTEMPT3='Attempt 3/3: could not resolve latest patchcov version (API: Bad credentials)'
W_FALLBACK="The GitHub API gave no release after 3 attempts (API: Bad credentials), so latest patchcov was resolved from the github.com releases/latest redirect instead: v0.1.1. Check that github-token holds a valid token (it defaults to the workflow token), or set 'version' to a release to skip the lookup."
W_NODE='Node.js 20 is deprecated. The following actions target Node.js 20 but are being forced to run on Node.js 24: actions/cache@v4'
W_OTHER='No artifacts found for the given name'

# The shape of a real log: the echo of a step's script, which holds the same words as the
# message it would print and is colour-coded, so it does not start with the marker; the
# warnings as the runner printed them; and lines that mention a warning without being one.
warning_log() {
  printf '\357\273\277%s\n' "2026-10-04T04:12:20.1Z Current runner version: '2.329.0'"
  printf '%s\n' \
    "2026-10-04T04:12:29.0Z ${ESC}[36;1m  echo \"::warning::Attempt \${attempt}/3: could not resolve latest patchcov version (API: \${api_message})\"${ESC}[0m" \
    '2026-10-04T04:12:29.1Z ##[endgroup]' \
    "2026-10-04T04:12:29.3Z ##[warning]$W_ATTEMPT1" \
    "2026-10-04T04:12:32.4Z ##[warning]$W_ATTEMPT2" \
    "2026-10-04T04:12:38.6Z ##[warning]$W_ATTEMPT3" \
    "2026-10-04T04:12:38.8Z ##[warning]$W_FALLBACK" \
    "2026-10-04T04:12:40.0Z ##[warning]$W_NODE" \
    "2026-10-04T04:12:41.0Z ##[warning]$W_OTHER" \
    '2026-10-04T04:12:42.0Z warning: --format is deprecated; use -o/--output instead' \
    '2026-10-04T04:12:42.1Z ##[error]Process completed with exit code 1.' \
    '2026-10-04T04:12:42.2Z a step printed ##[warning]this, which is not at the start of its line'
}

d=$(fresh)
add_job "$d" 601 'Latest patchcov (API refuses the token)'
warning_log >"$d/logs/601"
run_warnings "$d" 'Latest patchcov (API refuses the token)'
pass "warnings: reads a job's log" test "$STATUS" -eq 0
eq "warnings: prints each ##[warning] line without its timestamp or marker" \
  "$W_ATTEMPT1
$W_ATTEMPT2
$W_ATTEMPT3
$W_FALLBACK
$W_NODE
$W_OTHER" "$OUT"
pass "warnings: not the echoed script, which holds the same words" \
  bash -c '! grep -qF "echo" <<<"$1"' _ "$OUT"
pass "warnings: not a program's own warning: line" \
  bash -c '! grep -qF "is deprecated; use -o/--output" <<<"$1"' _ "$OUT"
pass "warnings: not an error" \
  bash -c '! grep -qF "Process completed" <<<"$1"' _ "$OUT"
pass "warnings: not a marker in the middle of a line" \
  bash -c '! grep -qF "this, which is not" <<<"$1"' _ "$OUT"
pass "fixture: the log does echo the warning's words outside a warning line" \
  grep -qF 'echo "::warning::Attempt' "$d/logs/601"
pass "fixture: the log does hold the marker in the middle of a line" \
  grep -qF 'a step printed ##[warning]this' "$d/logs/601"

# What a caller does with them is its own: each of the runner's lines is one the reader
# prints, so a caller that wants the fallback's picks it by its words.
pass "warnings: the fallback's warning is among them, whole" \
  grep -qxF "$W_FALLBACK" <<<"$OUT"

printf '%s\r\n' "2026-10-04T04:12:38.8Z ##[warning]$W_FALLBACK" >"$d/logs/601"
run_warnings "$d" 'Latest patchcov (API refuses the token)'
eq "warnings: strips carriage returns" "$W_FALLBACK" "$OUT"

printf '%s\n' "2026-10-04T04:12:42.0Z warning: --format is deprecated; use -o/--output instead" \
  "2026-10-04T04:12:42.1Z ##[error]Process completed with exit code 1." >"$d/logs/601"
run_warnings "$d" 'Latest patchcov (API refuses the token)'
pass "warnings: a log without one is not a failure" test "$STATUS" -eq 0
eq "warnings: a log without one prints nothing" "" "$OUT"

: >"$d/logs/601"
run_warnings "$d" 'Latest patchcov (API refuses the token)'
pass "warnings: an empty log is not a failure" test "$STATUS" -eq 0
eq "warnings: an empty log prints nothing" "" "$OUT"

# The plumbing is job-log.sh's, shared with the other readers and tested above for it;
# these show this one fails the same way, with no warning printed.
run_warnings "$d" 'No such job'
pass "warnings: a missing job fails the script" test "$STATUS" -ne 0
pass "warnings: and is named" grep -q "0 jobs named 'No such job'" <<<"$ERR"
eq "warnings: and prints nothing" "" "$OUT"

d=$(fresh)
add_job "$d" 602 'Job'
warning_log >"$d/logs/602"
run_warnings "$d" 'Job' FAKE_FAIL_FIRST=99 JOB_LOG_ATTEMPTS=2
pass "warnings: a log that is never readable fails the script" test "$STATUS" -ne 0
pass "warnings: and says so" grep -q "could not read the log of job 'Job' (602) after 2 attempts" <<<"$ERR"
eq "warnings: and prints nothing" "" "$OUT"

# --- the assertion in failure-messages reads what the action logs ----------------------

# `failure-messages` asserts from ONE warning of scenario 10's job. The fragments it holds
# are fixed strings, so a rewording of the action's warning would fail the assertion on a
# runner; these hold the two ends to each other here, read from the files and not copied.
# The warning is the `::warning::` line of the resolve step that says the redirect answered,
# and it starts with `${api_gave}`, the text the step builds for what the API did. Scenario 10
# sends a token the API refuses with 401, so the one that matters is the refusal's (#62). The
# warning holds values the runner fills in, so each fragment of the workflow is paired with the
# text the action's script has for it: the API's reason (`Bad credentials` is what the API says
# to the token scenario 10 sends) and the tag, which the redirect's shape check says starts
# with `v`.
ACTION_TEXT="$(<"$ROOT/action.yml")"
WORKFLOW_TEXT="$(<"$ROOT/.github/workflows/integration.yml")"
FALLBACK_LINE="$(grep -F '::warning::${api_gave}, so latest patchcov was resolved' <<<"$ACTION_TEXT")"
REFUSED_LINE="$(grep -F 'api_gave="The GitHub API refused the request (HTTP ${refused})' <<<"$ACTION_TEXT")"
# The way out the warning ends in is `${fix}` since #63 (with no jq it names jq and not the token); scenario 10 has
# jq and its token refused, so it is the first assignment of `fix`, the token's.
FIX_LINE="$(grep -F 'fix="Check that github-token holds a valid token' <<<"$ACTION_TEXT")"
pass "action.yml: the fallback's warning is logged, once" test "$(grep -c . <<<"$FALLBACK_LINE")" -eq 1
pass "action.yml: the text for a refusal is built, once" test "$(grep -c . <<<"$REFUSED_LINE")" -eq 1
pass "action.yml: the way out for an API that answered is built, once" test "$(grep -c . <<<"$FIX_LINE")" -eq 1
has "action.yml: the fallback's warning ends in that way out" "$FALLBACK_LINE" '. ${fix}"'
has "workflow: failure-messages reads the warnings of scenario 10's job" "$WORKFLOW_TEXT" \
  "bash tests/job-warnings.sh 'Latest patchcov (API refuses the token)'"
while IFS='|' read -r in_workflow in_action source; do
  case "$source" in
    refused) line="$REFUSED_LINE" ;;
    fix) line="$FIX_LINE" ;;
    *) line="$FALLBACK_LINE" ;;
  esac
  has "action.yml: the $source line holds '$in_action'" "$line" "$in_action"
  has "workflow: ... and the assertion asks for '$in_workflow'" "$WORKFLOW_TEXT" "\"$in_workflow\""
done <<'EOF'
(API: Bad credentials)|(API: ${api_message|refused
so latest patchcov was resolved from the github.com releases/latest redirect instead: v|so latest patchcov was resolved from the github.com releases/latest redirect instead: ${RELEASE_TAG}|warning
set 'version' to a release to skip the lookup|set 'version' to a release to skip the lookup|fix
EOF
# The three checks as written: each holds the fallback's own words, and each of the other two
# fragments with it, so all three have to be in one warning (a fragment quoted by another call
# does not stand in for one a call dropped).
has "workflow: check 1 asks for the fallback and the reason, in one warning" "$WORKFLOW_TEXT" \
  "            expect \"10: the fallback's warning names the API's reason\" \"\$warnings\" \\
              \"\$fallback\" \"(API: Bad credentials)\""
has "workflow: check 2 asks for all three in one warning" "$WORKFLOW_TEXT" \
  "            expect \"10: ONE warning holds the reason, the redirect answering and the way out\" \"\$warnings\" \\
              \"(API: Bad credentials)\" \"\$fallback\" \"set 'version' to a release to skip the lookup\""
# The structure round them: the reading is a condition (a failed read ends the step red, and a
# failure under `bash -e` is not lost), and the else is what counts it.
has "workflow: the warnings are read as a condition" "$WORKFLOW_TEXT" \
  "          if warnings=\"\$(bash tests/job-warnings.sh 'Latest patchcov (API refuses the token)')\"; then"
has "workflow: a failed read is counted" "$WORKFLOW_TEXT" \
  "set 'version' to a release to skip the lookup\"
          else
            status=1
          fi
"
has "workflow: check 3 asks for the fallback and the way out, in one warning" "$WORKFLOW_TEXT" \
  "            expect \"10: the fallback's warning offers pinning 'version'\" \"\$warnings\" \\
              \"\$fallback\" \"set 'version' to a release to skip the lookup\""
has "workflow: the fallback's words are defined once, as the action logs them" "$WORKFLOW_TEXT" \
  '          fallback="so latest patchcov was resolved from the github.com releases/latest redirect instead: v"'
# The job's name is the one the `latest-redirect` job sets, and failure-messages needs the job.
has "workflow: the job name is scenario 10's" "$WORKFLOW_TEXT" "    name: Latest patchcov (API refuses the token)"

# --- the log itself -----------------------------------------------------------

d=$(fresh)
add_job "$d" 501 'Job'
deprecation_log >"$d/logs/501"
run_script "$LOG" "$d" 'Job'
pass "job-log: reads a job's log" test "$STATUS" -eq 0
eq "job-log: prints every line, carriage returns removed, nothing filtered" \
  "$(tr -d '\r' <"$d/logs/501")" "$OUT"

summary
