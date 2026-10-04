#!/usr/bin/env bash
# Tests for tests/check-deprecated-flags.sh. Plain bash, no framework:
#   tests/check-deprecated-flags.test.sh
# Exits non-zero if any case fails.
#
# What matters most is that the check cannot pass when it should not: it has to
# catch the flag in both shapes action.yml uses, name the line, and still catch it
# in the real action.yml (a mutated copy), where a restructure of the file would
# otherwise leave a check that passes on fixtures and finds nothing in practice.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/check-deprecated-flags.sh"
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

# run <file...>: runs the script, leaving its status in STATUS and its output
# (stdout and stderr together) in OUT.
run() {
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  STATUS=$?
}

# status_is <name> <want>: the last run exited with <want>.
status_is() {
  if [ "$STATUS" -eq "$2" ]; then ok "$1"; else bad "$1" "exit $STATUS, want $2; output: $OUT"; fi
}

# has <name> <fragment>: the last run's output holds the fixed string.
has() {
  if grep -qF -- "$2" <<<"$OUT"; then ok "$1"; else bad "$1" "output lacks '$2': $OUT"; fi
}

# lacks <name> <fragment>: the last run's output does not hold the fixed string.
lacks() {
  if grep -qF -- "$2" <<<"$OUT"; then bad "$1" "output holds '$2': $OUT"; else ok "$1"; fi
}

# --- the flag on the invocation line -----------------------------------------

cat >"$WORK/invocation.yml" <<'EOF'
run: |
  omni-dev coverage diff --report r.lcov --format markdown > coverage.md
EOF
run "$WORK/invocation.yml"
status_is "invocation line: fails" 1
has "invocation line: names the file and line" "file=$WORK/invocation.yml,line=2,"
has "invocation line: names the replacement" "pass -o/--output instead"
has "invocation line: shows the line" "--report r.lcov --format markdown"

# --- the flag inside an args array, away from the omni-dev call ---------------

cat >"$WORK/array.yml" <<'EOF'
args=(coverage diff
  --report r.lcov
  --format json)
omni-dev "${args[@]}"
EOF
run "$WORK/array.yml"
status_is "args array: fails" 1
has "args array: names the line of the flag, not of the call" "line=3,"

cat >"$WORK/append.yml" <<'EOF'
args+=(--format json)
EOF
run "$WORK/append.yml"
status_is "args+=: fails" 1

# --- the flag spelled with =, and as the last word of a line ------------------

printf 'omni-dev coverage diff --format=json\n' >"$WORK/equals.yml"
run "$WORK/equals.yml"
status_is "--format=json: fails" 1

printf 'omni-dev coverage diff --report r.lcov --format\n' >"$WORK/last.yml"
run "$WORK/last.yml"
status_is "flag at the end of the line: fails" 1

printf -- '--format json\n' >"$WORK/first.yml"
run "$WORK/first.yml"
status_is "flag at the start of the line: fails" 1

# --- what is not a hit -------------------------------------------------------

cat >"$WORK/lookalikes.yml" <<'EOF'
args+=(--report-format lcov)
args+=(--baseline-report-format lcov)
args+=(--formatted json)
args+=(--format-x json)
args+=(-o json)
args+=(--output json)
EOF
run "$WORK/lookalikes.yml"
status_is "look-alikes and the replacement: pass" 0
has "pass: says what was scanned" "$WORK/lookalikes.yml"

cat >"$WORK/comments.yml" <<'EOF'
# --format was replaced by -o/--output in omni-dev 0.32.0
run: |
  # a shell comment about --format
      # an indented one: --format
  omni-dev coverage diff -o json
EOF
run "$WORK/comments.yml"
status_is "full-line comments: pass" 0

printf '%s\n' 'omni-dev coverage diff -o json # not --format' >"$WORK/trailing.yml"
run "$WORK/trailing.yml"
status_is "a trailing comment still counts (only full-line comments are skipped)" 1

# --- several hits, several files ---------------------------------------------

cat >"$WORK/two.yml" <<'EOF'
a --format x
b -o x
c --format y
EOF
printf 'ok\n--format z\n' >"$WORK/second.sh"
run "$WORK/two.yml" "$WORK/second.sh"
status_is "several hits: fails" 1
has "several hits: first line of the first file" "file=$WORK/two.yml,line=1,"
has "several hits: second line of the first file" "file=$WORK/two.yml,line=3,"
has "several hits: line numbers restart in the next file" "file=$WORK/second.sh,line=2,"
lacks "several hits: a clean line is not reported" "file=$WORK/two.yml,line=2,"

# --- a missing file is an error, not a pass ----------------------------------

run "$WORK/no-such-file.yml"
status_is "missing file: exit 2, not a pass" 2
has "missing file: says which" "no such file: $WORK/no-such-file.yml"

run "$WORK/lookalikes.yml" "$WORK/no-such-file.yml"
status_is "one missing file among good ones: exit 2" 2

# --- the real files ----------------------------------------------------------

# No arguments: the files and the directory the workflow runs it on, from any cwd.
OUT="$(cd "$WORK" && bash "$SCRIPT" 2>&1)"
STATUS=$?
status_is "default scan of the repository passes" 0
has "default scan: covers action.yml" "action.yml"
has "default scan: covers the scripts" "scripts/combine-shards.sh"

# The same check must find the flag in the real action.yml. Rewriting its `-o`
# call sites back to `--format` is what a regression would look like. The copy
# must differ, or a reworded call site would leave this passing for nothing.
sed -e 's/ -o markdown/ --format markdown/g' -e 's/ -o json/ --format json/g' \
  "$ROOT/action.yml" >"$WORK/mutated-action.yml"
if cmp -s "$ROOT/action.yml" "$WORK/mutated-action.yml"; then
  bad "mutation: action.yml has -o markdown / -o json call sites to rewrite" "the rewrite changed nothing"
else
  ok "mutation: action.yml has -o markdown / -o json call sites to rewrite"
  run "$WORK/mutated-action.yml"
  status_is "mutation: action.yml with --format fails" 1
  # Every rewritten line is reported, one annotation each.
  want="$(grep -c -e '--format' "$WORK/mutated-action.yml")"
  got="$(grep -c '^::error file=' <<<"$OUT")"
  if [ "$want" -gt 0 ] && [ "$got" -eq "$want" ]; then
    ok "mutation: every rewritten call site is reported ($got)"
  else
    bad "mutation: every rewritten call site is reported" "$got annotations for $want lines: $OUT"
  fi
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
