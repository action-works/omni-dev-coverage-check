#!/usr/bin/env bash
# Tests for what the merge queue on `main` relies on (#76). Plain bash, no framework:
#   tests/merge-queue.test.sh
# Exits non-zero if any case fails.
#
# Two things are tested, because neither shows until the ruleset exists and a mistake in
# either leaves a pull request that cannot merge, or one that merges red:
#
#   1. tests/ci-gate.sh, the script the `ci-gate` job runs: red unless every job it needs
#      succeeded, `skipped` included (GitHub counts a skipped required check as passing).
#   2. The wiring in .github/workflows: `ci-gate` needs every other job of
#      integration.yml, and `failure-messages` every job but those two (#105); `ci-gate`
#      runs `if: always()` and reads its results through `env:`; the
#      three workflows a required check comes from run on `merge_group` (without it the
#      check never reports for the queue's commit and the pull request waits forever); the
#      two path-filtered ones do not (CLAUDE.md: never required); and the required checks'
#      names are still the jobs' names, since the ruleset selects them by name.
#
# The wiring checks are one function over a directory, run on the real workflows and on
# copies broken one way at a time, so each check is shown to fail. The workflows are
# read with awk, POSIX (the ubuntu runners' default is mawk: no regex intervals), and a
# layout the readers cannot read (a flow-style `needs: [a, b]`, `on: [push]`) is refused
# rather than read wrongly, as tests/step-lib.sh does for action.yml.

# The awk programs and the `${{ }}` text below are single-quoted on purpose: awk and the
# workflow read them, not the shell.
# shellcheck disable=SC2016
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GATE="$DIR/ci-gate.sh"
WORKFLOWS="${WORKFLOWS:-$ROOT/.github/workflows}"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# --- 1. tests/ci-gate.sh --------------------------------------------------------------

# run_gate <the NEEDS value>: sets STATUS and OUT (stdout and stderr).
run_gate() {
  OUT="$(NEEDS="$1" "$BASH" "$GATE" 2>&1)"
  STATUS=$?
}

# What `toJSON(needs)` really holds: an object keyed by job id, each with a `result` and
# its `outputs`.
ALL_OK='{"a":{"result":"success","outputs":{}},"b":{"result":"success","outputs":{"x":"1"}},"c":{"result":"success","outputs":{}}}'
run_gate "$ALL_OK"
eq "every job succeeded: passes" 0 "$STATUS"
has "  and says how many" "$OUT" "ok   - ci-gate: all 3 jobs succeeded"
lacks "  and logs no error" "$OUT" "::error::"

run_gate '{"a":{"result":"success"},"b":{"result":"failure"},"c":{"result":"success"}}'
eq "one job failed: red" 1 "$STATUS"
has "  and names it" "$OUT" "::error::b finished 'failure', not 'success'"
has "  and counts it" "$OUT" "::error::ci-gate: 1 of 3 jobs did not succeed"
has "  and still lists the ones that passed" "$OUT" "ok   - a"

run_gate '{"a":{"result":"success"},"b":{"result":"cancelled"}}'
eq "one job was cancelled: red" 1 "$STATUS"
has "  and names it" "$OUT" "::error::b finished 'cancelled', not 'success'"

# The case the gate exists for: `failure-messages` is skipped because a scenario failed, a
# skipped required check passes, and only this job is left to say so.
run_gate '{"thin-mode":{"result":"failure"},"failure-messages":{"result":"skipped"}}'
eq "a scenario failed and failure-messages was skipped: red" 1 "$STATUS"
has "  and names the scenario" "$OUT" "::error::thin-mode finished 'failure', not 'success'"
has "  and the skipped job" "$OUT" "::error::failure-messages finished 'skipped', not 'success'"
has "  and counts both" "$OUT" "::error::ci-gate: 2 of 2 jobs did not succeed"

# Skipped alone is red too, not a pass: it is why the rule is "anything but success".
run_gate '{"a":{"result":"success"},"failure-messages":{"result":"skipped"}}'
eq "failure-messages skipped, nothing else red: still red" 1 "$STATUS"
has "  and names it" "$OUT" "::error::failure-messages finished 'skipped', not 'success'"

run_gate '{"a":{"result":"failure"},"b":{"result":"failure"},"c":{"result":"cancelled"}}'
eq "every job red: red" 1 "$STATUS"
has "  and counts all of them" "$OUT" "::error::ci-gate: 3 of 3 jobs did not succeed"

# A result this script has never seen is not a pass.
run_gate '{"a":{"result":"success"},"b":{"result":"neutral"}}'
eq "an unknown result: red" 1 "$STATUS"

# A job id is from the workflow file, but one that holds a newline must not start a
# workflow command of its own.
run_gate "$(jq -cn '{"a\n::error::forged":{"result":"success"},"b":{"result":"failure"}}')"
eq "a job id with a newline: still judged" 1 "$STATUS"
lacks "  and no line starts a command of its own" "$OUT"$'\n' $'\n::error::forged'

# Nothing to judge is refused (status 2), not passed: a gate over no jobs is how a deleted
# `needs:` would go unnoticed.
refuses() {
  local name=$1 value=$2
  run_gate "$value"
  eq "$name: refused" 2 "$STATUS"
  has "  and says so" "$OUT" "::error::ci-gate.sh did not get a non-empty object of jobs that each have a result"
}
refuses "an empty object" '{}'
refuses "an array" '[]'
refuses "null" 'null'
refuses "a string" '"success"'
refuses "not JSON" 'success'
refuses "a job with no result" '{"a":{"outputs":{}}}'
refuses "a result that is not a string" '{"a":{"result":true}}'
refuses "one good job and one without a result" '{"a":{"result":"success"},"b":{}}'

# toJSON(needs) is pretty-printed; the dump has to be on the one line a workflow command reads.
run_gate $'{\n  "a": {}\n}'
has "  and a multi-line dump is on one line" "$OUT" '$NEEDS is: {   "a": {} }'

run_gate ''
eq "NEEDS empty: refused" 2 "$STATUS"
has "  and says so" "$OUT" "::error::ci-gate.sh needs the needs context in \$NEEDS"

OUT="$(env -u NEEDS "$BASH" "$GATE" 2>&1)"
STATUS=$?
eq "NEEDS unset: refused" 2 "$STATUS"
has "  and says so" "$OUT" "::error::ci-gate.sh needs the needs context in \$NEEDS"

# No jq on PATH: said, not a pass (the script uses only builtins until it needs jq).
mkdir "$WORK/empty"
OUT="$(PATH="$WORK/empty" NEEDS="$ALL_OK" "$BASH" "$GATE" 2>&1)"
STATUS=$?
eq "no jq on PATH: refused" 2 "$STATUS"
has "  and says so" "$OUT" "::error::ci-gate.sh needs jq"

# A jq that answers the check and then dies on the listing must not read as "no failure":
# a loop over no jobs counts none. The stub is the real jq for its first call only.
mkdir "$WORK/flaky"
cat > "$WORK/flaky/jq" <<EOF
#!$BASH
count="$WORK/flaky/count"
n=\$(cat "\$count" 2>/dev/null || echo 0)
echo \$((n + 1)) > "\$count"
[ "\$n" -lt 1 ] || exit 5
exec "$(command -v jq)" "\$@"
EOF
chmod +x "$WORK/flaky/jq"
OUT="$(PATH="$WORK/flaky:$PATH" NEEDS='{"a":{"result":"failure"}}' "$BASH" "$GATE" 2>&1)"
STATUS=$?
eq "jq dies after the check, on a red job: refused, not passed" 2 "$STATUS"
has "  and says so" "$OUT" "::error::ci-gate.sh could not list the jobs"
lacks "  and does not claim success" "$OUT" "all 0 jobs succeeded"

# --- 2. the workflows -----------------------------------------------------------------

# job_lines <workflow>: every line under `jobs:`, tagged with the job it belongs to, as
# `<job><TAB><line>` (a comment or a blank line between two jobs goes with the one above it,
# which no use below minds). The one place that knows the layout of `jobs:`; the readers
# after it are built on it. Refuses a file with no jobs.
job_lines() {
  awk '
    /^jobs:[ \t]*$/ { j = 1; next }
    j && /^[^ \t#]/ { j = 0 }
    j && /^  [^ \t#]/ { cur = $0; sub(/^  /, "", cur); sub(/:.*/, "", cur); n++ }
    j && n { print cur "\t" $0 }
    END { if (!n) { print "no jobs under a top-level `jobs:`" > "/dev/stderr"; exit 1 } }
  ' "$1"
}

# jobs_of <workflow>: the job ids, one per line, in file order.
jobs_of() {
  job_lines "$1" | awk -F'\t' '!seen[$1]++ { print $1 }'
}

# job_block <workflow> <job>: the job's lines, its key line included. Refuses a job that is
# not in the file.
job_block() {
  job_lines "$1" | JOB="$2" awk -F'\t' '
    $1 == ENVIRON["JOB"] { print substr($0, length($1) + 2); found = 1 }
    END { if (!found) { print "no job " ENVIRON["JOB"] > "/dev/stderr"; exit 1 } }
  '
}

# job_needs <workflow> <job>: what the job lists under `needs:`, one per line (none for a
# job with no `needs:`). Refuses a `needs:` that is not a block list.
job_needs() {
  job_block "$1" "$2" | awk '
    /^    needs:[ \t]*$/ { inneeds = 1; next }
    /^    needs:/ { print "needs is not a block list" > "/dev/stderr"; exit 1 }
    inneeds {
      if ($0 ~ /^      - /) { x = $0; sub(/^      - /, "", x); sub(/[ \t]*(#.*)?$/, "", x); print x; next }
      if ($0 ~ /^[ \t]*(#.*)?$/) next
      inneeds = 0
    }
  '
}

# triggers_of <workflow>: the events under the top-level `on:`, one per line. Refuses an
# `on:` that is not a block.
triggers_of() {
  awk '
    /^on:[ \t]*$/ { on = 1; seen = 1; next }
    /^on:/ { print "on: is not a block" > "/dev/stderr"; bad = 1; exit 1 }
    on && /^[^ \t#]/ { on = 0 }
    on && /^  [^ \t#]/ { k = $0; sub(/^  /, "", k); sub(/:.*/, "", k); print k }
    END { if (bad) exit 1; if (!seen) { print "no top-level on:" > "/dev/stderr"; exit 1 } }
  ' "$1"
}

# wiring_problems <directory of the workflows>: one line per problem, nothing if there is
# none.
wiring_problems() {
  local dir=$1 integration="$1/integration.yml" err="$WORK/reader.err" jobs needs fm_needs job block events wf

  if ! jobs="$(jobs_of "$integration" 2>"$err")"; then
    echo "cannot read the jobs of integration.yml: $(<"$err")"
  elif ! needs="$(job_needs "$integration" ci-gate 2>"$err")"; then
    echo "cannot read the needs of ci-gate: $(<"$err")"
  else
    # A job nothing waits for is a job that can be red while the queue merges.
    while IFS= read -r job; do
      [ "$job" != ci-gate ] || continue
      grep -Fxq -- "$job" <<<"$needs" || echo "ci-gate does not need: $job"
    done <<<"$jobs"
    while IFS= read -r job; do
      [ -n "$job" ] || continue
      grep -Fxq -- "$job" <<<"$jobs" || echo "ci-gate needs a job that does not exist: $job"
    done <<<"$needs"

    # failure-messages reads the finished log of every job through the API, and its deprecation
    # step reads EVERY job that finished green, so a job missing from its `needs` can still be
    # running when it reads, and it would assert on a log that is not finished (#105). It needs
    # everything but itself and ci-gate, which waits for it: needing ci-gate would be a cycle.
    if ! fm_needs="$(job_needs "$integration" failure-messages 2>"$err")"; then
      echo "cannot read the needs of failure-messages: $(<"$err")"
    else
      while IFS= read -r job; do
        case "$job" in ci-gate | failure-messages) continue ;; esac
        grep -Fxq -- "$job" <<<"$fm_needs" || echo "failure-messages does not need: $job"
      done <<<"$jobs"
      while IFS= read -r job; do
        [ -n "$job" ] || continue
        grep -Fxq -- "$job" <<<"$jobs" || echo "failure-messages needs a job that does not exist: $job"
        [ "$job" != ci-gate ] || echo "failure-messages needs ci-gate, which needs it: a cycle"
        [ "$job" != failure-messages ] || echo "failure-messages needs itself"
      done <<<"$fm_needs"
    fi

    # A job-level `continue-on-error` lets a red job report `success`, which passes the gate;
    # a job-level `if:` can make it `skipped`, which turns the gate red on every run it
    # does not apply to. ci-gate's rule (anything but success is red) is safe only while
    # neither exists.
    while IFS= read -r job; do
      [ "$job" != ci-gate ] || continue
      block="$(job_block "$integration" "$job")"
      grep -Eq '^    (if|continue-on-error):' <<<"$block" \
        && echo "$job has a job-level if: or continue-on-error:, which ci-gate cannot see through"
    done <<<"$jobs"
  fi

  block="$(job_block "$integration" ci-gate)"
  grep -Eq '^    if: (\$\{\{ always\(\) \}\}|always\(\))$' <<<"$block" \
    || echo "ci-gate does not run 'if: always()', so it is skipped when a job it needs fails"
  grep -Fxq '          NEEDS: ${{ toJSON(needs) }}' <<<"$block" \
    || echo "ci-gate does not read the results through env: NEEDS: \${{ toJSON(needs) }}"
  grep -Fxq '        run: bash tests/ci-gate.sh' <<<"$block" \
    || echo "ci-gate's step does not run exactly 'bash tests/ci-gate.sh' (no expression in the script)"
  [ "$(grep -c 'run:' <<<"$block")" -eq 1 ] \
    || echo "ci-gate has more or fewer than one run: step"
  ! grep -q 'continue-on-error' <<<"$block" \
    || echo "ci-gate has continue-on-error, so it cannot fail the check"

  # merge_group on the workflows a required check comes from, and not on the path-filtered
  # ones.
  for wf in integration test commit-check; do
    if ! events="$(triggers_of "$dir/$wf.yml" 2>"$err")"; then
      echo "cannot read the triggers of $wf.yml: $(<"$err")"
    else
      grep -Fxq merge_group <<<"$events" \
        || echo "$wf.yml does not run on merge_group, so its required check never reports in the queue"
    fi
  done
  for wf in pr-paths e2e-sharded; do
    if ! events="$(triggers_of "$dir/$wf.yml" 2>"$err")"; then
      echo "cannot read the triggers of $wf.yml: $(<"$err")"
    else
      ! grep -Fxq merge_group <<<"$events" \
        || echo "$wf.yml runs on merge_group, but it is path-filtered and must never be required"
    fi
  done

  # The ruleset selects a check by the name of its job.
  grep -Fxq '    name: Validate Commit Messages' "$dir/commit-check.yml" \
    || echo "commit-check.yml has no job named 'Validate Commit Messages'"
  grep -Fxq '    name: Shell scripts' "$dir/test.yml" \
    || echo "test.yml has no job named 'Shell scripts'"
  grep -Fxq '    name: ci-gate' "$integration" \
    || echo "integration.yml has no job named 'ci-gate'"
}

eq "the workflows: no wiring problem" "" "$(wiring_problems "$WORKFLOWS")"

# The real workflow's list, to run the real gate over it.
REAL_NEEDS="$(job_needs "$WORKFLOWS/integration.yml" ci-gate)"
pass "ci-gate needs something" test -n "$REAL_NEEDS"

# needs_json <result for every job> [<job> <result>]...: the `toJSON(needs)` of the real
# ci-gate, every job with the first result and the named ones with their own.
needs_json() {
  local all=$1 job json
  shift
  json='{}'
  while IFS= read -r job; do
    json="$(jq -c --arg k "$job" --arg v "$all" '.[$k] = {result: $v, outputs: {}}' <<<"$json")"
  done <<<"$REAL_NEEDS"
  while [ "$#" -ge 2 ]; do
    json="$(jq -c --arg k "$1" --arg v "$2" 'if has($k) then .[$k].result = $v else error("no job " + $k) end' <<<"$json")"
    shift 2
  done
  printf '%s\n' "$json"
}

run_gate "$(needs_json success)"
eq "the real needs, all successful: passes" 0 "$STATUS"
run_gate "$(needs_json success failure-messages skipped)"
eq "the real needs, failure-messages skipped: red, not skipped" 1 "$STATUS"
run_gate "$(needs_json success fat-mode failure failure-messages skipped)"
eq "the real needs, a scenario red and failure-messages skipped: red" 1 "$STATUS"
has "  and names the scenario" "$OUT" "::error::fat-mode finished 'failure', not 'success'"

# Each way to break the wiring, on a copy of the real workflows, must be reported. Every
# edit is checked to have changed the copy: a no-op would pass for the wrong reason.
mutant=0
# mutate <name> <file> <awk program over the file> <fragment the problems must hold>
mutate() {
  local name=$1 file=$2 program=$3 fragment=$4 dir
  mutant=$((mutant + 1))
  dir="$WORK/mutant-$mutant"
  mkdir "$dir"
  cp "$WORKFLOWS"/*.yml "$dir/"
  awk "$program" "$WORKFLOWS/$file" > "$dir/$file"
  if cmp -s "$WORKFLOWS/$file" "$dir/$file"; then
    bad "$name" "the edit did not change $file"
    return
  fi
  has "$name" "$(wiring_problems "$dir")" "$fragment"
}

# Every edit to ci-gate's `needs` is scoped to ci-gate's own block, so it holds wherever the job
# sits in the file. IN_JOB tracks the current job; the program that follows it runs after.
IN_JOB='/^  [^ \t#]/ { cur = $0; sub(/^  /, "", cur); sub(/:.*/, "", cur) }'
mutate "a need dropped (version-pin)" integration.yml \
  "$IN_JOB"' cur == "ci-gate" && /^      - version-pin$/ { next } { print }' "ci-gate does not need: version-pin"
mutate "a need dropped (failure-messages)" integration.yml \
  "$IN_JOB"' cur == "ci-gate" && /^      - failure-messages$/ { next } { print }' "ci-gate does not need: failure-messages"
# Appended after ci-gate, with a `needs:` of its own: the readers must not take its list for
# ci-gate's.
mutate "a job added after ci-gate that it does not need" integration.yml \
  '{ print } END { print ""; print "  brand-new-job:"; print "    needs:"; print "      - thin-mode"; print "    runs-on: ubuntu-latest"; print "    steps: []" }' \
  "ci-gate does not need: brand-new-job"
# failure-messages' own list (#105), scoped to its block as ci-gate's edits are to ci-gate's.
mutate "failure-messages: a need dropped (linux-compatibility)" integration.yml \
  "$IN_JOB"' cur == "failure-messages" && /^      - linux-compatibility$/ { next } { print }' "failure-messages does not need: linux-compatibility"
mutate "failure-messages: the first need dropped (thin-mode)" integration.yml \
  "$IN_JOB"' cur == "failure-messages" && /^      - thin-mode$/ { next } { print }' "failure-messages does not need: thin-mode"
mutate "failure-messages: the last need dropped (deprecation-control)" integration.yml \
  "$IN_JOB"' cur == "failure-messages" && /^      - deprecation-control$/ { next } { print }' "failure-messages does not need: deprecation-control"
mutate "failure-messages: a need that is not a job" integration.yml \
  "$IN_JOB"' { print } cur == "failure-messages" && /^      - linux-compatibility$/ { print "      - not-a-job" }' \
  "failure-messages needs a job that does not exist: not-a-job"
# A bogus name that is a substring of a real job is still a name that is no job (a `grep -F` without
# `-x` would find `thin` inside `thin-mode`).
mutate "failure-messages: a need that is only a substring of a job" integration.yml \
  "$IN_JOB"' { print } cur == "failure-messages" && /^      - linux-compatibility$/ { print "      - thin" }' \
  "failure-messages needs a job that does not exist: thin"
mutate "failure-messages: a job added after it that it does not need" integration.yml \
  '{ print } END { print ""; print "  brand-new-job:"; print "    needs:"; print "      - thin-mode"; print "    runs-on: ubuntu-latest"; print "    steps: []" }' \
  "failure-messages does not need: brand-new-job"
mutate "failure-messages: it needs ci-gate, a cycle" integration.yml \
  "$IN_JOB"' { print } cur == "failure-messages" && /^      - linux-compatibility$/ { print "      - ci-gate" }' \
  "failure-messages needs ci-gate, which needs it: a cycle"
mutate "failure-messages: it needs itself" integration.yml \
  "$IN_JOB"' { print } cur == "failure-messages" && /^      - linux-compatibility$/ { print "      - failure-messages" }' \
  "failure-messages needs itself"
mutate "failure-messages: no needs at all" integration.yml \
  "$IN_JOB"' cur == "failure-messages" && /^    needs:[ \t]*$/ { skip = 1; next } skip && /^      - / { next } { skip = 0; print }' \
  "failure-messages does not need: thin-mode"
# With no list at all, only the jobs it lacks are named: no phantom empty name for the list's absence.
eq "failure-messages: no needs at all: no empty name is reported as a job that does not exist" 0 \
  "$(wiring_problems "$WORK/mutant-$mutant" | grep -c 'failure-messages needs a job that does not exist' || true)"
mutate "failure-messages: renamed, so the job is not there" integration.yml \
  '$0 == "  failure-messages:" { print "  messages:"; next } { print }' "cannot read the needs of failure-messages"
mutate "a need that is not a job" integration.yml \
  "$IN_JOB"' { print } cur == "ci-gate" && /^      - failure-messages$/ { print "      - not-a-job" }' \
  "ci-gate needs a job that does not exist: not-a-job"
mutate "a needed job given a job-level if:" integration.yml \
  '{ print } /^  version-pin:$/ { print "    if: false" }' "version-pin has a job-level if: or continue-on-error:"
mutate "a needed job given a job-level continue-on-error" integration.yml \
  '{ print } /^  fat-mode:$/ { print "    continue-on-error: true" }' "fat-mode has a job-level if: or continue-on-error:"
mutate "the if: removed" integration.yml '$0 != "    if: ${{ always() }}"' "does not run 'if: always()'"
mutate "the if: made !cancelled()" integration.yml \
  '$0 == "    if: ${{ always() }}" { print "    if: ${{ !cancelled() }}"; next } { print }' "does not run 'if: always()'"
mutate "the env mapping removed" integration.yml '$0 != "          NEEDS: ${{ toJSON(needs) }}"' "does not read the results through env"
mutate "an expression in the script" integration.yml \
  '$0 == "        run: bash tests/ci-gate.sh" { print "        run: bash tests/ci-gate.sh ${{ toJSON(needs) }}"; next } { print }' \
  "does not run exactly 'bash tests/ci-gate.sh'"
mutate "continue-on-error on the gate" integration.yml \
  '{ print } $0 == "    if: ${{ always() }}" { print "    continue-on-error: true" }' "continue-on-error"
mutate "the job renamed" integration.yml '$0 == "    name: ci-gate" { print "    name: gate"; next } { print }' \
  "integration.yml has no job named 'ci-gate'"

mutate "merge_group dropped from integration.yml" integration.yml '$0 != "  merge_group:"' \
  "integration.yml does not run on merge_group"
mutate "merge_group dropped from test.yml" test.yml '$0 != "  merge_group:"' "test.yml does not run on merge_group"
mutate "merge_group dropped from commit-check.yml" commit-check.yml '$0 != "  merge_group:"' \
  "commit-check.yml does not run on merge_group"
mutate "merge_group added to pr-paths.yml" pr-paths.yml '{ print } /^on:[ \t]*$/ { print "  merge_group:" }' \
  "pr-paths.yml runs on merge_group"
mutate "merge_group added to e2e-sharded.yml" e2e-sharded.yml '{ print } /^on:[ \t]*$/ { print "  merge_group:" }' \
  "e2e-sharded.yml runs on merge_group"
mutate "Shell scripts renamed" test.yml '$0 == "    name: Shell scripts" { print "    name: Shell checks"; next } { print }' \
  "test.yml has no job named 'Shell scripts'"
mutate "Validate Commit Messages renamed" commit-check.yml \
  '$0 == "    name: Validate Commit Messages" { print "    name: Validate commits"; next } { print }' \
  "commit-check.yml has no job named 'Validate Commit Messages'"

# The readers refuse what they cannot read, so a reformatted file is reported, not read
# as if it held nothing.
mutate "a flow-style needs: is refused" integration.yml \
  "$IN_JOB"' cur == "ci-gate" && /^    needs:[ \t]*$/ { print "    needs: [thin-mode]"; skip = 1; next } skip && /^      - / { next } { skip = 0; print }' \
  "cannot read the needs of ci-gate"
mutate "failure-messages: a flow-style needs: is refused" integration.yml \
  "$IN_JOB"' cur == "failure-messages" && /^    needs:[ \t]*$/ { print "    needs: [thin-mode]"; skip = 1; next } skip && /^      - / { next } { skip = 0; print }' \
  "cannot read the needs of failure-messages"
mutate "a flow-style on: is refused" test.yml '/^on:[ \t]*$/ { print "on: [push, pull_request]"; skip = 1; next } skip && /^  / { next } /^[^ \t]/ { skip = 0 } { print }' \
  "cannot read the triggers of test.yml"

# The readers on their own: comments and trailing comments inside a list are not needs,
# and a job with no `needs:` has none.
cat > "$WORK/reader.yml" <<'EOF'
name: x
on:
  # a comment at the trigger level
  push:
    branches: [main]
  merge_group:
jobs:
  # a comment between jobs
  first:
    runs-on: ubuntu-latest
  second:
    needs:
      - first # trailing comment
      # a comment inside the list

      - third
    runs-on: ubuntu-latest
  third:
    runs-on: ubuntu-latest
EOF
eq "jobs_of reads the ids and skips comments" "first,second,third" "$(jobs_of "$WORK/reader.yml" | paste -sd, -)"
eq "job_needs reads a list past comments and blanks" "first,third" "$(job_needs "$WORK/reader.yml" second | paste -sd, -)"
eq "job_needs: a job with no needs has none" "" "$(job_needs "$WORK/reader.yml" first)"
quietly() { "$@" 2>/dev/null; }
fail "job_needs: a job that is not there is refused" quietly job_needs "$WORK/reader.yml" nonexistent
eq "triggers_of reads the events, not their settings" "push,merge_group" "$(triggers_of "$WORK/reader.yml" | paste -sd, -)"
fail "jobs_of: a file with no jobs is refused" quietly jobs_of "$ROOT/CLAUDE.md"

summary
