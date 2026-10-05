#!/usr/bin/env bash
# Tests for the steps of action.yml that read a caller's input: how the commands, the test
# arguments, the report path, the merge-base and the gate thresholds reach the tools they
# drive. Plain bash, no framework:
#   tests/input-steps.test.sh
# Exits non-zero if any case fails.
#
# The runner used to replace each `${{ inputs.* }}` in these scripts with its value before
# the shell parsed them, so a value that held shell syntax ran as shell (#39). Each step now
# reads its values from environment variables its `env:` block fills. This runs every such
# step as the runner would, with the variables set by the case, against stub `cargo`, `git`,
# `omni-dev` and `sudo` that log their arguments, and asserts what the tools were asked to
# do. The scripts are read out of action.yml itself, so renaming a step or moving its
# `run:` block fails here, by name, rather than leaving a test of a copy. The steps with
# their own tests (platform, guard, resolve-version) are not repeated here.
#
# What it pins that a plain run cannot show: that a value holding quotes, `$`, backticks,
# spaces or a `;` reaches a tool as the one argument it was (and never runs), that
# `test-args` and `worktree-system-deps` are split on whitespace and refuse what used to be
# shell, that the two command inputs are still shell (one shell, `-e`, the instrumentation
# env), and that the action's own variables are not left in the environment of the code a
# caller owns. Hostile values carry a canary: a command that would create a file under
# $WORK, and every case asserts the file is absent.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# --- the stubs ------------------------------------------------------------------------

BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/stub" <<'EOF'
#!/usr/bin/env bash
# One stub for every tool. It logs one line per call, each argument in brackets, and which
# of the action's variables were still in its environment.
name="$(basename "$0")"
if [ "$name $1 $2" = "cargo llvm-cov show-env" ]; then
  echo 'export CARGO_LLVM_COV_STUB=1'
  exit 0
fi
{ printf '%s' "$name"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >>"$CALLS_LOG"
leak=""
for v in TEST_ARGS SETUP_COMMANDS EXTRA_TEST_COMMANDS VERSION REPORT WORKTREE_SYSTEM_DEPS BASE_SHA; do
  if printenv "$v" >/dev/null 2>&1; then leak="$leak $v"; fi
done
[ -z "$leak" ] || echo "$name:$leak" >>"$LEAK_LOG"
prev=""
for a in "$@"; do
  [ "$prev" != "--output-path" ] || echo "TN:stub" >"$a"
  prev="$a"
done
case "$name" in
  git)
    case "$1" in
      merge-base) echo "mergebase0123456789" ;;
      worktree) mkdir -p "$3" ;;
    esac
    ;;
  omni-dev)
    out=""
    prev=""
    for a in "$@"; do
      [ "$prev" != "-o" ] || out="$a"
      prev="$a"
    done
    if [ "$out" = json ]; then
      echo '{"patch_coverage":{"percent":50},"project_delta":{"total_after":60}}'
      exit "${OMNI_EXIT_JSON:-${OMNI_EXIT:-0}}"
    fi
    echo md
    exit "${OMNI_EXIT:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$BIN/stub"
for tool in cargo git omni-dev sudo; do ln -s stub "$BIN/$tool"; done

CANARIES=0
# canary: prints a path under $WORK that a hostile value tries to create, a fresh one each time.
canary() {
  CANARIES=$((CANARIES + 1))
  echo "$WORK/pwned.$CANARIES"
}

# run_step <step name> [VAR=value ...]: runs the step as the runner would, in a fresh
# directory, with the variables given. $PRE, when set, is run in that directory first.
# Sets STATUS, OUT (stdout and stderr), CASE (the directory), REPO (its working directory),
# CALLS (what the stubs were asked, one call per line), LEAKS (which of the action's
# variables a stub still saw) and GH_OUTPUT (what the step wrote to $GITHUB_OUTPUT).
run_step() {
  local name=$1 script
  shift
  if ! script="$(step_run "$name")"; then
    bad "read the '$name' step out of action.yml"
    STATUS=99 OUT="" CALLS="" LEAKS="" GH_OUTPUT=""
    return
  fi
  CASE="$(mktemp -d "$WORK/case.XXXXXX")"
  REPO="$CASE/repo"
  mkdir "$REPO"
  : >"$CASE/calls.log"
  : >"$CASE/leak.log"
  : >"$CASE/output"
  [ -z "${PRE:-}" ] || (cd "$REPO" && eval "$PRE")
  OUT="$(cd "$REPO" && env PATH="$BIN:$PATH" HOME="$CASE" CALLS_LOG="$CASE/calls.log" \
    LEAK_LOG="$CASE/leak.log" GITHUB_OUTPUT="$CASE/output" GITHUB_WORKSPACE="$REPO" "$@" \
    bash --noprofile --norc -eo pipefail -c "$script" 2>&1)"
  STATUS=$?
  CALLS="$(cat "$CASE/calls.log")"
  LEAKS="$(cat "$CASE/leak.log")"
  GH_OUTPUT="$(cat "$CASE/output")"
}

# absent <name> <path>: the canary file was never created.
absent() {
  if [ ! -e "$2" ]; then ok "$1"; else bad "$1" "$2 exists: a value ran as shell"; fi
}

# --- the wiring: each step's env: block fills each variable from the right place -------

# The cases below set the variables, so they would pass if `env:` filled one from the wrong
# input. Each line is `step | variable | expression`.
# shellcheck disable=SC2016
WIRING='Check the ignore-filename-regex value|IGNORE_FILENAME_REGEX|inputs.ignore-filename-regex
Install omni-dev from source|VERSION|steps.resolve-version.outputs.version
Download pre-built binary|DOWNLOAD_URL|steps.platform.outputs.download-url
Download pre-built binary|BINARY_NAME|steps.platform.outputs.binary-name
Combine shard reports|ACTION_PATH|github.action_path
Coverage setup commands|SETUP_COMMANDS|inputs.setup-commands
Run tests with coverage|TEST_ARGS|inputs.test-args
Run extra (gated) tests with coverage|EXTRA_TEST_COMMANDS|inputs.extra-test-commands
Generate head coverage report (lcov)|REPORT|inputs.report
Determine merge-base|BASE_REF|inputs.base-ref
Compute baseline from merge-base (fallback)|REPORT|inputs.report
Compute baseline from merge-base (fallback)|WORKTREE_SYSTEM_DEPS|inputs.worktree-system-deps
Compute baseline from merge-base (fallback)|TEST_ARGS|inputs.test-args
Compute baseline from merge-base (fallback)|BASE_SHA|steps.mb.outputs.sha
Build coverage diff|REPORT|inputs.report
Build coverage diff|COLLAPSE_RANGES|inputs.collapse-ranges
Build coverage diff|ALL_FILES|inputs.all-files
Build coverage diff|STRIP_PREFIX|inputs.strip-prefix
Build coverage diff|REPORT_FORMAT|inputs.report-format
Build coverage diff|BASE_SHA|steps.mb.outputs.sha
Build coverage diff|IGNORE_FILENAME_REGEX|inputs.ignore-filename-regex
Enforce patch-coverage gate|REPORT|inputs.report
Enforce patch-coverage gate|BASE_SHA|steps.mb.outputs.sha
Enforce patch-coverage gate|FAIL_UNDER_PATCH|inputs.fail-under-patch
Enforce patch-coverage gate|STRIP_PREFIX|inputs.strip-prefix
Enforce patch-coverage gate|REPORT_FORMAT|inputs.report-format
Enforce patch-coverage gate|IGNORE_FILENAME_REGEX|inputs.ignore-filename-regex
Enforce line-coverage gate|FAIL_UNDER_LINES|inputs.fail-under-lines
Enforce line-coverage gate (thin mode)|REPORT|inputs.report
Enforce line-coverage gate (thin mode)|BASE_SHA|steps.mb.outputs.sha
Enforce line-coverage gate (thin mode)|FAIL_UNDER_LINES|inputs.fail-under-lines
Enforce line-coverage gate (thin mode)|STRIP_PREFIX|inputs.strip-prefix
Enforce line-coverage gate (thin mode)|REPORT_FORMAT|inputs.report-format
Enforce line-coverage gate (thin mode)|IGNORE_FILENAME_REGEX|inputs.ignore-filename-regex'
while IFS='|' read -r step var expr; do
  # shellcheck disable=SC2016
  has "env: $step: $var is $expr" "$(step_block "$step")" "        $var: \${{ $expr }}"
done <<<"$WIRING"

# --- Check the ignore-filename-regex value (#48) --------------------------------------------

IGNORE_STEP="Check the ignore-filename-regex value"
# The value is a comma-separated list on one line and nothing is trimmed, so a newline, or a
# space or tab at either end or beside a comma, would become part of a pattern that matches no
# path: nothing is excluded and nothing says so. The step refuses it, with a message that names
# the input and the fix. It sits where a mistake in a workflow file fails fastest, first, and
# runs where the value is used.
# shellcheck disable=SC2016
eq "ignore-filename-regex: it runs where the value is used (the guard's own third need)" \
  "inputs.ignore-filename-regex != '' && (github.event_name == 'pull_request' || (inputs.run-coverage != 'true' && inputs.fail-under-lines != ''))" \
  "$(step_field "$IGNORE_STEP" if)"
eq "ignore-filename-regex: it is the first step of the action, ahead of any install" \
  "$IGNORE_STEP" "$(grep -m1 '^    - name: ' "$ACTION" | sed 's/^    - name: //')"

expect_refused() { # <name> <value> <what the error says the value holds>
  run_step "$IGNORE_STEP" "IGNORE_FILENAME_REGEX=$2"
  eq "ignore-filename-regex, $1: the step fails" 1 "$STATUS"
  has "ignore-filename-regex, $1: the error names the input and what it holds" "$OUT" \
    "::error::The 'ignore-filename-regex' input holds $3"
  has "ignore-filename-regex, $1: it says the file would stay with no warning" "$OUT" \
    "which matches no path: the files would stay in the comment and the gates, with no warning"
  has "ignore-filename-regex, $1: it says what to write" "$OUT" "Write all the patterns on ONE line with bare commas ('a,b')"
  has "ignore-filename-regex, $1: it says to write one line, and what a YAML block does" "$OUT" \
    "a YAML | block keeps its line breaks (|- only drops the last one)"
  has "ignore-filename-regex, $1: it says how to write a space that is meant" "$OUT" "Write [ ] for a space that is meant"
  # Non-empty lines: a line break in the value must not make a second line, which a runner
  # would read as another workflow command.
  eq "ignore-filename-regex, $1: it logs one line, whatever the value held" 1 "$(grep -c . <<<"$OUT" || true)"
  eq "ignore-filename-regex, $1: it runs nothing" "" "$CALLS"
}
expect_accepted() { # <name> <value>
  run_step "$IGNORE_STEP" "IGNORE_FILENAME_REGEX=$2"
  eq "ignore-filename-regex, $1: the step passes" 0 "$STATUS"
  eq "ignore-filename-regex, $1: and says nothing" "" "$OUT"
}

# The rows of the issue's table, each of which excluded nothing.
expect_refused "a trailing newline (what a YAML | block gives)" $'patch-fixture\n' "a line break"
expect_refused "a leading space" ' patch-fixture' "a space or tab at the start or end"
expect_refused "a space after the comma" 'nomatch, patch-fixture' "a space or tab beside a comma"
expect_refused "a newline between patterns" $'nomatch\npatch-fixture' "a line break"
# The neighbours of those rows.
expect_refused "a trailing space" 'patch-fixture ' "a space or tab at the start or end"
expect_refused "a space before the comma" 'nomatch ,patch-fixture' "a space or tab beside a comma"
expect_refused "spaces on both sides of the comma" 'a , b' "a space or tab beside a comma"
expect_refused "a leading tab" $'\tpatch-fixture' "a space or tab at the start or end"
expect_refused "a tab after the comma" $'a,\tb' "a space or tab beside a comma"
expect_refused "a carriage return" $'patch-fixture\r' "a line break"
expect_refused "CRLF between patterns" $'a\r\nb' "a line break"
expect_refused "a block of several lines" $'a\nb\nc\n' "a line break"
expect_refused "only a space" ' ' "a space or tab at the start or end"
expect_refused "a space after a comma that ends the value" 'a, ' "a space or tab at the start or end"

# What is shown of it: a line break is a ?, and says so; a value with nothing unprintable says
# nothing of a ?; and a long value is cut at 60.
run_step "$IGNORE_STEP" 'IGNORE_FILENAME_REGEX=a, b'
lacks "ignore-filename-regex: a plain space does not explain a ?" "$OUT" "where a ? stands for"
run_step "$IGNORE_STEP" $'IGNORE_FILENAME_REGEX=a\nb'
has "ignore-filename-regex: a line break does" "$OUT" "(got 'a?b', where a ? stands for a line break or another character that does not print)"
run_step "$IGNORE_STEP" $'IGNORE_FILENAME_REGEX=nomatch\n::error::forged'
has "ignore-filename-regex: a workflow command in the value is shown with the break replaced" "$OUT" "(got 'nomatch?::error::forged'"
long="$(printf 'x, %.0s' {1..40})"
run_step "$IGNORE_STEP" "IGNORE_FILENAME_REGEX=$long"
has "ignore-filename-regex: a long value is cut at 60 characters" "$OUT" "(got '${long:0:60}...'"

# The control: the same patterns written as the input wants them.
expect_accepted "one pattern" 'patch-fixture'
expect_accepted "bare commas" 'nomatch,patch-fixture'
expect_accepted "three patterns, one starting with a dash" '-sys/,src/gpu/,generated/'
expect_accepted "an empty piece (a doubled or trailing comma), which omni-dev ignores" 'a,,b,'
expect_accepted "a space inside a pattern, which is a character of it" 'src/my dir/'
expect_accepted "a space inside a pattern beside a comma-free neighbour" 'src/my dir/,src/other dir/x'
expect_accepted "a space written as [ ] beside a comma" 'a[ ],[ ]b'
expect_accepted "a regex that spells whitespace as \s" 'a\sb,c'
# shellcheck disable=SC2016
expect_accepted "regex specials" 'src/ignored\.rs$|a(b|c)+[0-9]*'

# Hostile text is data: the step reads the value from the environment and never evals it.
c="$(canary)"
run_step "$IGNORE_STEP" "IGNORE_FILENAME_REGEX=a,\$(touch $c),b"
eq "ignore-filename-regex: a command substitution with no space beside a comma passes" 0 "$STATUS"
absent "ignore-filename-regex: ... and ran nothing" "$c"
c="$(canary)"
run_step "$IGNORE_STEP" "IGNORE_FILENAME_REGEX=a, \$(touch $c)"
eq "ignore-filename-regex: a command substitution after a space beside a comma is refused" 1 "$STATUS"
absent "ignore-filename-regex: ... and ran nothing" "$c"

# --- Install omni-dev from source ------------------------------------------------------

run_step "Install omni-dev from source" VERSION=0.45.0
eq "source install: the step succeeds" 0 "$STATUS"
eq "source install: it asks cargo for exactly that version" \
  'cargo [install] [omni-dev] [--version] [0.45.0]' "$CALLS"
eq "source install: the build scripts do not see VERSION" "" "$LEAKS"

c="$(canary)"
run_step "Install omni-dev from source" VERSION="1.0\"; touch $c; \""
eq "source install, hostile version: it is one argument, as written" \
  "cargo [install] [omni-dev] [--version] [1.0\"; touch $c; \"]" "$CALLS"
absent "source install, hostile version: nothing ran" "$c"

# --- the two command inputs: shell, in one shell ----------------------------------------

# commands_cases <step name> <variable> <expect LLVM_PROFILE_FILE is /dev/null: yes|no>
commands_cases() {
  local step=$1 var=$2 profile=$3 c
  run_step "$step" "$var=echo ready > ran.txt"
  eq "$step: a command runs" 0 "$STATUS"
  eq "$step: a command ran in the checkout" "ready" "$(cat "$REPO/ran.txt")"

  run_step "$step" "$var=echo one > a.txt
echo two > b.txt
"
  eq "$step: several lines all run" "one two" "$(cat "$REPO/a.txt" "$REPO/b.txt" | tr '\n' ' ' | sed 's/ $//')"

  run_step "$step" "$var=X=1
f() { echo \"\$X\"; }
f > state.txt
cat <<TEXT > doc.txt
line \$X
TEXT"
  eq "$step: one shell: a variable and a function are shared across lines" "1" "$(cat "$REPO/state.txt")"
  eq "$step: a here-document works" "line 1" "$(cat "$REPO/doc.txt")"

  run_step "$step" "$var=echo \"a b\" 'c d' \$(echo sub) > quoted.txt"
  eq "$step: quotes and substitution are shell, as written" "a b c d sub" "$(cat "$REPO/quoted.txt")"

  # shellcheck disable=SC2016
  run_step "$step" "$var=echo '\${{ github.token }}' > literal.txt"
  # shellcheck disable=SC2016
  eq "$step: text that looks like an expression stays text" '${{ github.token }}' "$(cat "$REPO/literal.txt")"

  run_step "$step" "$var=false
echo after > after.txt"
  eq "$step: a failing line ends the step (-e)" 1 "$STATUS"
  absent "$step: the line after it did not run" "$REPO/after.txt"

  run_step "$step" "$var=false | cat
echo after > after.txt"
  eq "$step: a failing pipeline ends the step (pipefail)" 1 "$STATUS"

  run_step "$step" "$var=echo a > a.txt
exit 3"
  eq "$step: exit ends the step with that status" 3 "$STATUS"

  run_step "$step" "$var=printenv CARGO_LLVM_COV_STUB > env.txt"
  eq "$step: the instrumentation env is loaded" "1" "$(cat "$REPO/env.txt")"

  run_step "$step" "$var=printenv $var > seen.txt || echo none > seen.txt"
  eq "$step: the commands do not see the input's own variable" "none" "$(cat "$REPO/seen.txt")"

  run_step "$step" "$var=echo \"\${LLVM_PROFILE_FILE:-unset}\" > profile.txt"
  if [ "$profile" = yes ]; then
    eq "$step: profiling is sent to /dev/null" "/dev/null" "$(cat "$REPO/profile.txt")"
  else
    eq "$step: profiling is left alone" "unset" "$(cat "$REPO/profile.txt")"
  fi
}
commands_cases "Coverage setup commands" SETUP_COMMANDS yes
commands_cases "Run extra (gated) tests with coverage" EXTRA_TEST_COMMANDS no

# --- Run tests with coverage: whitespace-split arguments ---------------------------------

TESTS="Run tests with coverage"
run_step "$TESTS" TEST_ARGS="--all-features --workspace"
eq "tests: the step succeeds" 0 "$STATUS"
eq "tests: the default arguments reach cargo test as two words" \
  'cargo [test] [--all-features] [--workspace]' "$CALLS"
eq "tests: cargo does not see TEST_ARGS" "" "$LEAKS"

run_step "$TESTS" TEST_ARGS=""
eq "tests: no arguments is a plain cargo test" 'cargo [test]' "$CALLS"

run_step "$TESTS" TEST_ARGS="  --a   --b	--c "
eq "tests: runs of spaces and tabs separate words, the ends are trimmed" \
  'cargo [test] [--a] [--b] [--c]' "$CALLS"

run_step "$TESTS" TEST_ARGS="--a
--b"
eq "tests: a newline separates words (it once ended the command)" 'cargo [test] [--a] [--b]' "$CALLS"

run_step "$TESTS" TEST_ARGS="--workspace -- --skip slow --test-threads=1"
eq "tests: arguments after -- pass through" \
  'cargo [test] [--workspace] [--] [--skip] [slow] [--test-threads=1]' "$CALLS"

PRE='touch foo1 foo2 bar'
run_step "$TESTS" TEST_ARGS="foo* ?ar [b]ar"
unset PRE
eq "tests: glob characters stay literal, whatever files exist" \
  'cargo [test] [foo*] [?ar] [[b]ar]' "$CALLS"

# What used to be parsed as shell now fails, loudly and before cargo runs.
refused_test_args() { # <label> <value>
  local c
  c="$(canary)"
  run_step "$TESTS" TEST_ARGS="${2//@CANARY@/$c}"
  eq "tests, $1: the step fails" 1 "$STATUS"
  has "tests, $1: the error names the input" "$OUT" "::error::test-args holds a quote, a backslash, a dollar sign or a backtick"
  has "tests, $1: the error says what to write" "$OUT" "Write plain whitespace-separated arguments."
  eq "tests, $1: cargo was not run" "" "$CALLS"
  absent "tests, $1: nothing ran" "$c"
}
refused_test_args "a double-quoted argument" '--features "a b"'
refused_test_args "a single-quoted argument" "--skip 'slow test'"
# shellcheck disable=SC2016
refused_test_args "a variable" '--workspace $HOME'
# shellcheck disable=SC2016
refused_test_args "a command substitution" '--workspace $(touch @CANARY@)'
# shellcheck disable=SC2016
refused_test_args "a backtick substitution" '--workspace `touch @CANARY@`'
refused_test_args "a backslash continuation" "--workspace \\"
refused_test_args "a quote that closes a command" '--a"; touch @CANARY@; "'

# --- Generate head coverage report (lcov) -----------------------------------------------

run_step "Generate head coverage report (lcov)" REPORT="out dir/head.lcov"
eq "head report: a path with a space is one argument" \
  'cargo [llvm-cov] [report] [--lcov] [--output-path] [out dir/head.lcov]' "$CALLS"

# --- Determine merge-base ----------------------------------------------------------------

run_step "Determine merge-base" BASE_REF=""
eq "merge-base: with no base-ref it is the fork point from git" "sha=mergebase0123456789" "$GH_OUTPUT"
eq "merge-base: it asks git for exactly that" 'git [merge-base] [origin/main] [HEAD]' "$CALLS"

run_step "Determine merge-base" BASE_REF="origin/main~3"
eq "merge-base: a base-ref is the sha, and git is not asked" "sha=origin/main~3" "$GH_OUTPUT"
eq "merge-base: a base-ref makes no git call" "" "$CALLS"

c="$(canary)"
run_step "Determine merge-base" BASE_REF="a b; touch $c"
eq "merge-base: a hostile base-ref is the output, as written" "sha=a b; touch $c" "$GH_OUTPUT"
absent "merge-base: a hostile base-ref ran nothing" "$c"

# --- Compute baseline from merge-base (fallback) ------------------------------------------

RECOMPUTE="Compute baseline from merge-base (fallback)"
recompute_env=(REPORT=head.lcov WORKTREE_SYSTEM_DEPS="" TEST_ARGS="--all-features --workspace" BASE_SHA=mergebase0123456789)

PRE='mkdir baseline && echo present > baseline/head.lcov'
run_step "$RECOMPUTE" "${recompute_env[@]}"
unset PRE
eq "recompute: a baseline already there ends it at once" 0 "$STATUS"
has "recompute: it says so" "$OUT" "a baseline was downloaded; skipping recompute"
eq "recompute: it runs nothing" "" "$CALLS"

run_step "$RECOMPUTE" "${recompute_env[@]}"
eq "recompute: the step succeeds" 0 "$STATUS"
# A stale worktree is cleared and its records pruned before the add, and the worktree is removed
# when the step ends (#78); tests/recompute-worktree.test.sh runs that against a real git.
eq "recompute: no system deps means no sudo; the merge-base is checked out, measured and removed" \
  'git [worktree] [remove] [--force] [../base]
git [worktree] [prune]
git [worktree] [add] [../base] [mergebase0123456789]
cargo [llvm-cov] [--all-features] [--workspace] [--no-report]
cargo [llvm-cov] [report] [--lcov] [--output-path] [head.lcov]
git [worktree] [remove] [--force] [../base]' "$CALLS"
eq "recompute: the baseline is written for the diff" "yes" "$([ -f "$REPO/baseline/head.lcov" ] && echo yes || echo no)"
# git runs before the variables are dropped and needs them; the merge-base's tests, run by
# cargo after, must not see them.
eq "recompute: the merge-base's tests do not see the action's variables" "" "$(grep '^cargo:' <<<"$LEAKS" || true)"

run_step "$RECOMPUTE" REPORT=out/head.lcov WORKTREE_SYSTEM_DEPS="" TEST_ARGS="--lib --no-fail-fast" BASE_SHA=abc123
has "recompute: the test arguments are split" "$CALLS" 'cargo [llvm-cov] [--lib] [--no-fail-fast] [--no-report]'
has "recompute: the report is named by its basename in the worktree" "$CALLS" '[--output-path] [head.lcov]'

run_step "$RECOMPUTE" REPORT=head.lcov WORKTREE_SYSTEM_DEPS="libasound2-dev  libfoo-dev
libbar" TEST_ARGS="" BASE_SHA=abc123
eq "recompute: the packages are split on whitespace, a newline included" \
  'sudo [apt-get] [update]
sudo [apt-get] [install] [-y] [libasound2-dev] [libfoo-dev] [libbar]
git [worktree] [remove] [--force] [../base]
git [worktree] [prune]
git [worktree] [add] [../base] [abc123]
cargo [llvm-cov] [--no-report]
cargo [llvm-cov] [report] [--lcov] [--output-path] [head.lcov]
git [worktree] [remove] [--force] [../base]' "$CALLS"

PRE='touch libx-dev'
run_step "$RECOMPUTE" REPORT=head.lcov WORKTREE_SYSTEM_DEPS="lib*-dev" TEST_ARGS="" BASE_SHA=abc123
unset PRE
has "recompute: a glob in a package name is passed to apt as written" "$CALLS" 'sudo [apt-get] [install] [-y] [lib*-dev]'

run_step "$RECOMPUTE" REPORT=head.lcov WORKTREE_SYSTEM_DEPS="" TEST_ARGS="" BASE_SHA="a b"
has "recompute: a base with a space is one argument to git" "$CALLS" 'git [worktree] [add] [../base] [a b]'

refused_deps() { # <label> <value> <message fragment>
  local c
  c="$(canary)"
  run_step "$RECOMPUTE" REPORT=head.lcov WORKTREE_SYSTEM_DEPS="${2//@CANARY@/$c}" TEST_ARGS="" BASE_SHA=abc123
  eq "recompute, $1: the step fails" 1 "$STATUS"
  has "recompute, $1: the error says why" "$OUT" "$3"
  eq "recompute, $1: apt, git and cargo were not run" "" "$CALLS"
  absent "recompute, $1: nothing ran" "$c"
}
# An option for apt-get, not a package: -o runs a hook as root.
refused_deps "an option for apt-get" '-o DPkg::Pre-Invoke::=touch@CANARY@ libfoo' "holds '-o', which starts with a dash"
refused_deps "a long option for apt-get" 'libfoo --allow-unauthenticated' "holds '--allow-unauthenticated', which starts with a dash"
refused_deps "a quote" 'libfoo "libbar"' "::error::worktree-system-deps holds a quote, a backslash, a dollar sign or a backtick"
# shellcheck disable=SC2016
refused_deps "a command substitution" 'libfoo$(touch @CANARY@)' "::error::worktree-system-deps holds a quote"
# shellcheck disable=SC2016
refused_deps "a backtick" 'libfoo`touch @CANARY@`' "::error::worktree-system-deps holds a quote"

# --- Build coverage diff -------------------------------------------------------------------

DIFF="Build coverage diff"
diff_env=(REPORT=coverage-head.lcov BASE_SHA=mergebase0123456789 ARTIFACT_URL=https://example/artifact
  RUN_URL=https://example/run HEAD_SHA=headsha COMMIT_URL=https://example/commit
  COLLAPSE_RANGES=true ALL_FILES=false STRIP_PREFIX="" REPORT_FORMAT="" IGNORE_FILENAME_REGEX="")
DIFF_COMMON='[--report] [coverage-head.lcov] [--base-ref] [mergebase0123456789] [--artifact-url] [https://example/artifact] [--run-url] [https://example/run] [--base-sha] [mergebase0123456789] [--head-sha] [headsha] [--commit-url] [https://example/commit]'

run_step "$DIFF" "${diff_env[@]}"
eq "diff: the step succeeds" 0 "$STATUS"
eq "diff: defaults: the comment and the percentages are two calls with the same flags" \
  "omni-dev [coverage] [diff] $DIFF_COMMON [--collapse-ranges] [-o] [markdown]
omni-dev [coverage] [diff] $DIFF_COMMON [--collapse-ranges] [-o] [json]" "$CALLS"
eq "diff: it writes the comment path and the percentages" "comment-path=coverage.md
patch-percent=50
line-percent=60" "$GH_OUTPUT"
eq "diff: the comment is omni-dev's markdown" "md" "$(cat "$REPO/coverage.md")"

run_step "$DIFF" "${diff_env[@]}" COLLAPSE_RANGES=false ALL_FILES=true STRIP_PREFIX=/home/runner/work/r/r REPORT_FORMAT=lcov
has "diff: every option set: collapse off, all-files, strip-prefix and report-format" "$CALLS" \
  "$DIFF_COMMON [--all-files] [--strip-prefix] [/home/runner/work/r/r] [--report-format] [lcov] [-o] [markdown]"
lacks "diff: collapse-ranges off omits the flag" "$CALLS" "--collapse-ranges"

run_step "$DIFF" "${diff_env[@]}" COLLAPSE_RANGES=TRUE ALL_FILES=yes
lacks "diff: collapse-ranges is exactly 'true'" "$CALLS" "--collapse-ranges"
lacks "diff: all-files is exactly 'true'" "$CALLS" "--all-files"

PRE='mkdir baseline && echo x > baseline/coverage-head.lcov'
run_step "$DIFF" "${diff_env[@]}"
unset PRE
has "diff: a baseline for the report's basename is passed to omni-dev" "$CALLS" "[--baseline-report] [baseline/coverage-head.lcov]"

run_step "$DIFF" "${diff_env[@]}" REPORT="out dir/h.lcov" STRIP_PREFIX="a b"
has "diff: a report path with a space is one argument" "$CALLS" "[--report] [out dir/h.lcov]"
has "diff: a strip-prefix with a space is one argument" "$CALLS" "[--strip-prefix] [a b]"

c="$(canary)"
# shellcheck disable=SC2016
run_step "$DIFF" "${diff_env[@]}" STRIP_PREFIX="/a/\$b/\`touch $c\`/\"d\"; touch $c" REPORT_FORMAT="\$(touch $c)"
# shellcheck disable=SC2016
has "diff, hostile values: strip-prefix reaches omni-dev as one argument, as written" "$CALLS" \
  "[--strip-prefix] [/a/\$b/\`touch $c\`/\"d\"; touch $c]"
# shellcheck disable=SC2016
has "diff, hostile values: report-format reaches omni-dev as one argument, as written" "$CALLS" \
  "[--report-format] [\$(touch $c)]"
absent "diff, hostile values: nothing ran" "$c"

# A regex is full of backslashes, dollars and quotes, and may start with a dash (`-sys/`): it is
# one `--flag=value` argument, so clap cannot read it as a flag and the shell never sees it.
# shellcheck disable=SC2016
REGEX='-sys/,^src/a\.rs$,"q",$HOME,`x`'
run_step "$DIFF" "${diff_env[@]}" IGNORE_FILENAME_REGEX="$REGEX"
has "diff: ignore-filename-regex is one --flag=value argument, as written" "$CALLS" "[--ignore-filename-regex=$REGEX]"
c="$(canary)"
# shellcheck disable=SC2016
run_step "$DIFF" "${diff_env[@]}" IGNORE_FILENAME_REGEX="a,\$(touch $c)"
# shellcheck disable=SC2016
has "diff, hostile regex: it is one argument, as written" "$CALLS" "[--ignore-filename-regex=a,\$(touch $c)]"
absent "diff, hostile regex: nothing ran" "$c"
run_step "$DIFF" "${diff_env[@]}"
lacks "diff: no regex, no flag" "$CALLS" "--ignore-filename-regex"

run_step "$DIFF" "${diff_env[@]}" OMNI_EXIT=1
eq "diff: a failing comment diff fails the step" 1 "$STATUS"

run_step "$DIFF" "${diff_env[@]}" OMNI_EXIT_JSON=1
eq "diff: failing percentages never fail the build" 0 "$STATUS"
eq "diff: and it writes no percentages" "comment-path=coverage.md" "$GH_OUTPUT"

# --- Enforce patch-coverage gate -----------------------------------------------------------

PATCH="Enforce patch-coverage gate"
patch_env=(REPORT=coverage-head.lcov BASE_SHA=mergebase0123456789 FAIL_UNDER_PATCH=80 STRIP_PREFIX="" REPORT_FORMAT="" IGNORE_FILENAME_REGEX="")
run_step "$PATCH" "${patch_env[@]}"
eq "patch gate: the step succeeds" 0 "$STATUS"
eq "patch gate: the threshold and the merge-base reach omni-dev" \
  'omni-dev [coverage] [diff] [--report] [coverage-head.lcov] [--base-ref] [mergebase0123456789] [--fail-under-patch] [80] [-o] [json]' "$CALLS"

PRE='mkdir baseline && echo x > baseline/coverage-head.lcov'
run_step "$PATCH" "${patch_env[@]}" STRIP_PREFIX=/p REPORT_FORMAT=llvm-cov-json
unset PRE
eq "patch gate: the parse-affecting flags and the baseline mirror the comment diff" \
  'omni-dev [coverage] [diff] [--report] [coverage-head.lcov] [--base-ref] [mergebase0123456789] [--fail-under-patch] [80] [-o] [json] [--strip-prefix] [/p] [--report-format] [llvm-cov-json] [--baseline-report] [baseline/coverage-head.lcov]' "$CALLS"

c="$(canary)"
run_step "$PATCH" "${patch_env[@]}" FAIL_UNDER_PATCH="80; touch $c" STRIP_PREFIX="\$(touch $c)"
has "patch gate, hostile values: the threshold is one argument, as written" "$CALLS" "[--fail-under-patch] [80; touch $c]"
absent "patch gate, hostile values: nothing ran" "$c"

run_step "$PATCH" "${patch_env[@]}" IGNORE_FILENAME_REGEX="$REGEX"
has "patch gate: the regex mirrors the comment diff, as one argument" "$CALLS" "[--ignore-filename-regex=$REGEX]"

run_step "$PATCH" "${patch_env[@]}" OMNI_EXIT=1
eq "patch gate: omni-dev failing the gate fails the step" 1 "$STATUS"

# --- Enforce line-coverage gate (fat mode) --------------------------------------------------

run_step "Enforce line-coverage gate" FAIL_UNDER_LINES=55.5
eq "line gate: the step succeeds" 0 "$STATUS"
eq "line gate: the threshold reaches cargo llvm-cov as one argument" \
  'cargo [llvm-cov] [report] [--summary-only] [--fail-under-lines] [55.5]' "$CALLS"

c="$(canary)"
run_step "Enforce line-coverage gate" FAIL_UNDER_LINES="55; touch $c"
has "line gate, hostile value: it is one argument, as written" "$CALLS" "[--fail-under-lines] [55; touch $c]"
absent "line gate, hostile value: nothing ran" "$c"

# --- Enforce line-coverage gate (thin mode) -------------------------------------------------

THIN="Enforce line-coverage gate (thin mode)"
thin_env=(REPORT=coverage-head.lcov BASE_SHA=mergebase0123456789 FAIL_UNDER_LINES=55 STRIP_PREFIX="" REPORT_FORMAT="" IGNORE_FILENAME_REGEX="")
run_step "$THIN" "${thin_env[@]}"
eq "thin gate: a pull request diffs against the merge-base" \
  'omni-dev [coverage] [diff] [--report] [coverage-head.lcov] [--base-ref] [mergebase0123456789] [--fail-under-lines] [55] [-o] [json]' "$CALLS"

run_step "$THIN" "${thin_env[@]}" BASE_SHA=""
has "thin gate: a push has no merge-base, so it diffs HEAD against itself" "$CALLS" "[--base-ref] [HEAD]"

run_step "$THIN" "${thin_env[@]}" STRIP_PREFIX=/p REPORT_FORMAT=lcov
eq "thin gate: the parse-affecting flags mirror the comment diff" \
  'omni-dev [coverage] [diff] [--report] [coverage-head.lcov] [--base-ref] [mergebase0123456789] [--fail-under-lines] [55] [-o] [json] [--strip-prefix] [/p] [--report-format] [lcov]' "$CALLS"

c="$(canary)"
run_step "$THIN" "${thin_env[@]}" FAIL_UNDER_LINES="55; touch $c" REPORT="r.lcov; touch $c"
has "thin gate, hostile values: the threshold is one argument, as written" "$CALLS" "[--fail-under-lines] [55; touch $c]"
has "thin gate, hostile values: the report is one argument, as written" "$CALLS" "[--report] [r.lcov; touch $c]"
absent "thin gate, hostile values: nothing ran" "$c"

run_step "$THIN" "${thin_env[@]}" IGNORE_FILENAME_REGEX="$REGEX"
has "thin gate: the regex mirrors the comment diff, as one argument" "$CALLS" "[--ignore-filename-regex=$REGEX]"

run_step "$THIN" "${thin_env[@]}" OMNI_EXIT=1
eq "thin gate: omni-dev failing the gate fails the step" 1 "$STATUS"

summary
