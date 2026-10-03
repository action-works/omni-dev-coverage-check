#!/usr/bin/env bash
# Tests for scripts/combine-shards.sh. Plain bash, no framework:
#   tests/combine-shards.test.sh
# Exits non-zero if any case fails.
#
# The shards are written the way `cargo llvm-cov` writes them: NO newline after
# the final `end_of_record`. That is the shape that made a bare `cat` silently
# lose a file, so a fixture with tidy trailing newlines would hide the bug.

# The `bash -c` snippets below are single-quoted on purpose: they expand in the
# child shell, with the file passed as $1.
# shellcheck disable=SC2016
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/combine-shards.sh"
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

# A fresh directory per case, so cases cannot see each other's files.
fresh() {
  local dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  echo "$dir"
}

# lcov_shard <path> <root> <file:line:hits>...: a shard in real llvm-cov shape.
lcov_shard() {
  local path=$1 root=$2
  shift 2
  local file="" out="" spec name line hits
  for spec in "$@"; do
    IFS=: read -r name line hits <<<"$spec"
    if [ "$name" != "$file" ]; then
      [ -z "$file" ] || out+=$'end_of_record\n'
      out+="SF:${root}/${name}"$'\n'
      file=$name
    fi
    out+="DA:${line},${hits}"$'\n'
  done
  # The final terminator has no newline, as in real llvm-cov output.
  printf '%send_of_record' "$out" >"$path"
}

# run_combine <dir> <shard-reports> [VAR=value...]: runs the script in <dir>,
# captures stdout+stderr in $OUT and the exit status in $STATUS.
run_combine() {
  local dir=$1 reports=$2
  shift 2
  OUT="$(cd "$dir" && env -i PATH="$PATH" SHARD_REPORTS="$reports" REPORT=combined.lcov \
    STRIP_PREFIX=/ws "$@" bash "$SCRIPT" 2>&1)"
  STATUS=$?
}

# --- the join ---------------------------------------------------------------

d=$(fresh)
lcov_shard "$d/shard-1.lcov" /ws src/a.rs:1:1 src/a.rs:2:0 src/b.rs:1:0
lcov_shard "$d/shard-2.lcov" /ws src/a.rs:1:0 src/a.rs:2:5 src/c.rs:1:1
run_combine "$d" $'shard-1.lcov\nshard-2.lcov'
check "joins two shards" test "$STATUS" -eq 0
check "puts every end_of_record on its own line (no glued SF:)" \
  bash -c '! grep -q "end_of_record." "$1"' _ "$d/combined.lcov"
check "keeps every file of every shard" \
  bash -c '[ "$(grep -c "^SF:" "$1")" -eq 4 ]' _ "$d/combined.lcov"
check "ends with a newline" \
  bash -c '[ "$(tail -c1 "$1" | od -An -c | tr -d " ")" = "\\n" ]' _ "$d/combined.lcov"

check "the combined report is readable like any other report (0644)" \
  test -n "$(find "$d/combined.lcov" -perm -044)"

# A bare cat is exactly what the script exists to avoid; prove the fixture would
# have caught it.
cat "$d/shard-1.lcov" "$d/shard-2.lcov" >"$d/bare-cat.lcov"
check "fixture: a bare cat does glue records (so the tests above bite)" \
  grep -q 'end_of_recordSF:' "$d/bare-cat.lcov"

# --- globs ------------------------------------------------------------------

d=$(fresh)
mkdir "$d/shards"
lcov_shard "$d/shards/shard-2.lcov" /ws src/a.rs:1:1
lcov_shard "$d/shards/shard-1.lcov" /ws src/a.rs:1:0
lcov_shard "$d/shards/shard-10.lcov" /ws src/a.rs:1:0
run_combine "$d" 'shards/shard-*.lcov'
check "expands a glob" test "$STATUS" -eq 0
check "reports every matched shard" bash -c '[ "$(grep -c "^SF:" "$1")" -eq 3 ]' _ "$d/combined.lcov"

run_combine "$d" $'shards/shard-*.lcov\nshards/shard-1.lcov'
cp "$d/combined.lcov" "$d/overlap.lcov"
run_combine "$d" 'shards/shard-*.lcov'
check "overlapping patterns de-duplicate to the same output" cmp -s "$d/overlap.lcov" "$d/combined.lcov"

run_combine "$d" $'shards/shard-2.lcov\nshards/shard-1.lcov\nshards/shard-10.lcov'
cp "$d/combined.lcov" "$d/ordered-a.lcov"
run_combine "$d" $'shards/shard-10.lcov\nshards/shard-1.lcov\nshards/shard-2.lcov'
check "the order the shards are listed in does not change the output" \
  cmp -s "$d/ordered-a.lcov" "$d/combined.lcov"

run_combine "$d" $'\n  shards/shard-1.lcov  \n\n'
check "ignores blank lines and surrounding whitespace" test "$STATUS" -eq 0

# --- failures name the shard -------------------------------------------------

d=$(fresh)
lcov_shard "$d/shard-1.lcov" /ws src/a.rs:1:1
run_combine "$d" $'shard-1.lcov\nshard-9.lcov'
check "a missing shard fails" test "$STATUS" -ne 0
check "a missing shard is named" grep -q "shard-9.lcov" <<<"$OUT"

run_combine "$d" 'nope-*.lcov'
check "a glob matching nothing fails" test "$STATUS" -ne 0
check "a glob matching nothing names the pattern" grep -q "nope-\*.lcov" <<<"$OUT"

: >"$d/empty.lcov"
run_combine "$d" $'shard-1.lcov\nempty.lcov'
check "an empty shard fails" test "$STATUS" -ne 0
check "an empty shard is named" grep -q "empty.lcov" <<<"$OUT"
check "a failed run writes no combined report" test ! -e "$d/combined.lcov"

printf 'TN:\nSF:/ws/src/a.rs\nend_of_record' >"$d/no-lines.lcov"
run_combine "$d" $'shard-1.lcov\nno-lines.lcov'
check "a shard with no line records fails" test "$STATUS" -ne 0
check "a shard with no line records is named" grep -q "no-lines.lcov" <<<"$OUT"

run_combine "$d" '   '
check "blank shard-reports fails" test "$STATUS" -ne 0

# --- mode and format guards --------------------------------------------------

run_combine "$d" 'shard-1.lcov' RUN_COVERAGE=true
check "fat mode is rejected" test "$STATUS" -ne 0

run_combine "$d" 'shard-1.lcov' REPORT_FORMAT=cobertura
check "a non-lcov report-format is rejected" test "$STATUS" -ne 0
run_combine "$d" 'shard-1.lcov' REPORT_FORMAT=lcov
check "report-format lcov is accepted" test "$STATUS" -eq 0
run_combine "$d" 'shard-1.lcov' REPORT_FORMAT=auto
check "report-format auto is accepted" test "$STATUS" -eq 0

run_combine "$d" '*.lcov' REPORT=shard-1.lcov
check "a report that its own patterns match is rejected" test "$STATUS" -ne 0

# --- workspace prefix --------------------------------------------------------

d=$(fresh)
lcov_shard "$d/shard-1.lcov" /ws src/a.rs:1:1
lcov_shard "$d/shard-2.lcov" /somewhere/else src/a.rs:1:1
run_combine "$d" $'shard-1.lcov\nshard-2.lcov'
check "a shard under another root still combines" test "$STATUS" -eq 0
check "a shard under another root draws a warning" grep -q '^::warning::.*shard-2.lcov' <<<"$OUT"
check "the in-tree shard draws none" bash -c '! grep -q "warning.*shard-1.lcov" <<<"$1"' _ "$OUT"

lcov_shard "$d/mixed.lcov" /ws src/a.rs:1:1
printf '\nSF:/rustc/abc/library/core/src/option.rs\nDA:1,1\nend_of_record' >>"$d/mixed.lcov"
run_combine "$d" 'mixed.lcov'
check "a few out-of-tree paths are not a warning" bash -c '! grep -q "::warning::" <<<"$1"' _ "$OUT"

lcov_shard "$d/rel.lcov" . src/a.rs:1:1
run_combine "$d" 'rel.lcov'
check "relative paths are not a warning" bash -c '! grep -q "::warning::" <<<"$1"' _ "$OUT"

run_combine "$d" 'shard-2.lcov' STRIP_PREFIX=/somewhere/else
check "STRIP_PREFIX is honoured" bash -c '! grep -q "::warning::" <<<"$1"' _ "$OUT"

# --- output ------------------------------------------------------------------

d=$(fresh)
lcov_shard "$d/shard-1.lcov" /ws src/a.rs:1:1
lcov_shard "$d/shard-2.lcov" /ws src/a.rs:1:1
run_combine "$d" 'shard-*.lcov' REPORT=out/nested/combined.lcov GITHUB_OUTPUT="$d/gh-output"
check "creates the report's directory" test -s "$d/out/nested/combined.lcov"
check "writes the shard count" grep -qx 'count=2' "$d/gh-output"
check "writes the shard files, comma-separated" grep -qx 'files=shard-1.lcov,shard-2.lcov' "$d/gh-output"
check "leaves no temp file behind" bash -c '[ -z "$(find "$1" -name "*.??????" -path "*out*")" ]' _ "$d"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
