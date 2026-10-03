#!/usr/bin/env bash
# Tests for tests/job-errors.sh. Plain bash, no framework:
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

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/job-errors.sh"
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

# check <name> <command...>: passes when the command succeeds.
check() {
  local name=$1
  shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}

# equals <name> <expected> <actual>
equals() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected: $2 | got: $3"; fi
}

# A fresh directory per case, with the fake gh and an empty set of jobs.
fresh() {
  local dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$dir/bin" "$dir/logs"
  cat >"$dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Fake `gh api`: serves $FAKE_DIR/jobs.json and $FAKE_DIR/logs/<job id>, and fails
# the first $FAKE_FAIL_FIRST log reads the way a log that is not there yet does.
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
    if [ -n "${FAKE_JOBS_FAIL:-}" ]; then
      echo "gh: Not Found (HTTP 404)" >&2
      echo '{"message":"Not Found"}'
      exit 1
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

# run_errors <dir> <job name> [VAR=value...]: runs the script, capturing stdout in
# $OUT, stderr in $ERR and the exit status in $STATUS.
run_errors() {
  local dir=$1 name=$2
  shift 2
  OUT="$(env -i PATH="$dir/bin:$PATH" FAKE_DIR="$dir" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 \
    JOB_LOG_DELAY=0 "$@" bash "$SCRIPT" "$name" 2>"$dir/stderr")"
  STATUS=$?
  ERR="$(cat "$dir/stderr")"
}

# The log of a job that ran the guard and the shard combine, and failed them
# both: what a real log holds, in order. The first line has the byte-order mark.
LOG_TWO_ERRORS="$(printf '\357\273\277%s\n' \
  "2026-10-03T15:44:19.7678995Z Current runner version: '2.329.0'")
2026-10-03T15:44:33.4843361Z $(printf '\033[36;1m')if ! grep -q -- '--fail-under-lines' <<<\"\$help\"; then$(printf '\033[0m')
2026-10-03T15:44:33.4843944Z $(printf '\033[36;1m')  echo \"::error::\$(omni-dev --version) has no 'coverage diff --fail-under-lines', which thin mode uses\"$(printf '\033[0m')
2026-10-03T15:44:33.4891094Z ##[endgroup]
2026-10-03T15:44:33.5179483Z ##[error]shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
2026-10-03T15:44:33.5180225Z ##[error]Process completed with exit code 1."

# --- reading the messages -----------------------------------------------------

d=$(fresh)
add_job "$d" 101 'Thin mode (omni-dev latest)'
printf '%s\n' "$LOG_TWO_ERRORS" >"$d/logs/101"
run_errors "$d" 'Thin mode (omni-dev latest)'
check "reads a job's log" test "$STATUS" -eq 0
equals "prints each error message without its timestamp or marker" \
  "shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
Process completed with exit code 1." "$OUT"
check "does not return the echoed script, which holds the same message text" \
  bash -c '! grep -qF "has no" <<<"$1"' _ "$OUT"
check "fixture: the log does echo the message text outside an error line" \
  grep -qF "has no 'coverage diff" "$d/logs/101"

# A gh that refuses escape sequences, like the one on a current runner, must be
# given the flag; an older one has no such flag and must not be.
run_errors "$d" 'Thin mode (omni-dev latest)' FAKE_GH_OLD=1
check "reads the log with a gh that has no --allow-escape-sequences" test "$STATUS" -eq 0
equals "and prints the same messages" \
  "shard-reports pattern 'shards/missing-*.lcov' matched no files; a shard that never uploaded would silently lower coverage
Process completed with exit code 1." "$OUT"
check "fixture: a current gh does refuse this log without the flag" \
  bash -c '! env -i PATH="$1/bin:$PATH" FAKE_DIR="$1" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 \
    gh api "repos/o/r/actions/jobs/101/logs" >/dev/null 2>&1' _ "$d"

printf '%s\r\n' "2026-10-03T15:44:33.5179483Z ##[error]a message" >"$d/logs/101"
run_errors "$d" 'Thin mode (omni-dev latest)'
equals "strips carriage returns" "a message" "$OUT"

printf '%s\n' "2026-10-03T15:44:33.5179483Z echo ##[error]not a runner marker" \
  "2026-10-03T15:44:33.5179483Z ##[group]Run something" >"$d/logs/101"
run_errors "$d" 'Thin mode (omni-dev latest)'
equals "a step's own output that merely contains the marker does not count" "" "$OUT"

printf '%s\n' "2026-10-03T15:44:33.5179483Z ##[group]Run something" >"$d/logs/101"
run_errors "$d" 'Thin mode (omni-dev latest)'
check "a log without errors is not a failure" test "$STATUS" -eq 0
equals "a log without errors prints nothing" "" "$OUT"

# --- finding the job ----------------------------------------------------------

d=$(fresh)
add_job "$d" 201 'Thin mode (omni-dev 0.45.0)'
add_job "$d" 202 'Thin mode (omni-dev latest)'
add_job "$d" 203 'Thin mode (omni-dev latest) and more'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 201" >"$d/logs/201"
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 202" >"$d/logs/202"
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]from 203" >"$d/logs/203"
run_errors "$d" 'Thin mode (omni-dev latest)'
equals "picks the job by its exact name" "from 202" "$OUT"

run_errors "$d" 'Thin mode (omni-dev 0.4'
check "a name that only prefixes another is not found" test "$STATUS" -ne 0
check "a missing job is named in the error" grep -q "0 jobs named 'Thin mode (omni-dev 0.4'" <<<"$ERR"

add_job "$d" 204 'Thin mode (omni-dev latest)'
run_errors "$d" 'Thin mode (omni-dev latest)'
check "two jobs with one name are ambiguous, not the first" test "$STATUS" -ne 0
check "an ambiguous name is reported" grep -q "2 jobs named" <<<"$ERR"

run_errors "$d" 'Thin mode (omni-dev 0.45.0)' FAKE_JOBS_FAIL=1
check "a failed jobs call fails the script" test "$STATUS" -ne 0
check "and is not mistaken for a missing job or an unreadable log" \
  bash -c '! grep -q "jobs named\|could not read the log" <<<"$1"' _ "$ERR"
check "and shows the API's own error, not a parse error after it" \
  bash -c 'grep -q "Not Found" <<<"$1" && ! grep -q "jq:" <<<"$1"' _ "$ERR"
equals "and prints no messages" "" "$OUT"

# --- reading the log may take a few tries -------------------------------------

d=$(fresh)
add_job "$d" 301 'Job'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]late" >"$d/logs/301"
run_errors "$d" 'Job' FAKE_FAIL_FIRST=2 JOB_LOG_ATTEMPTS=6
check "retries a log that is not readable yet" test "$STATUS" -eq 0
equals "and then returns it" "late" "$OUT"
equals "reading it took three tries" 3 "$(cat "$d/log-reads")"

d=$(fresh)
add_job "$d" 302 'Job'
printf '%s\n' "2026-10-03T15:44:33.5Z ##[error]never" >"$d/logs/302"
run_errors "$d" 'Job' FAKE_FAIL_FIRST=99 JOB_LOG_ATTEMPTS=3
check "gives up on a log that never becomes readable" test "$STATUS" -ne 0
equals "after exactly the attempts it was given" 3 "$(cat "$d/log-reads")"
check "and says which job" grep -q "could not read the log of job 'Job' (302) after 3 attempts" <<<"$ERR"
check "and why, in gh's own words" grep -q "after 3 attempts: gh: Not Found (HTTP 404)" <<<"$ERR"
equals "and prints no messages" "" "$OUT"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
