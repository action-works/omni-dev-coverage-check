#!/usr/bin/env bash
# Tests for the steps of action.yml that run `cargo llvm-cov report`, and what each does with
# the `llvm-cov-ignore-filename-regex` input (#2). Plain bash, no framework:
#   tests/llvm-cov-ignore-steps.test.sh
# Exits non-zero if any case fails.
#
# The five steps (the head lcov, codecov.json, the summary, the line gate and the report inside
# the merge-base recompute) are read out of action.yml and run against a stub `cargo` that
# logs its arguments. What is pinned is the argument vector cargo-llvm-cov receives:
#   - unset, there is no `--ignore-filename-regex` at all: cargo-llvm-cov rejects an empty one,
#     and an action that does not use the input must not change what it runs;
#   - set, exactly one `--ignore-filename-regex=<value>` reaches the `report` call, byte for
#     byte, as ONE argument: a value that starts with `-`, holds spaces, `\`, `$`, quotes, a
#     backtick, glob characters or a newline is not split, expanded or read as a flag, and a
#     comma stays in it (cargo-llvm-cov takes one regex; `ignore-filename-regex`'s comma list is
#     omni-dev's);
#   - nothing else of the call changes, and no other cargo call gets the flag (the recompute's
#     `--no-report` build, `show-env`).
# A static check reads every step's code (its whole block, comments left out, so an inline
# `run:` counts too) and requires the steps that run `cargo llvm-cov report` to be the five run
# here, each taking the value from `env:` and running in fat mode only, and every other
# `cargo llvm-cov` call to be `show-env`, `clean` or a `--no-report` run. So a new report step,
# or a run that writes a report without saying `report` (`cargo llvm-cov --lcov`, a `report`
# on the next line), fails this test until it takes the filter too: a report that leaves it out
# measures files the others do not, and nothing else notices.
#
# What this does not reach: that the real cargo-llvm-cov honours the flag (the `fat-mode` job of
# integration.yml checks that on a runner, and the `recompute` job of pr-paths.yml checks the
# recompute's), and what a thin-mode run does (no job sets the input there; the five steps'
# `if:` is pinned below as text, not run).

# The `${{ ... }}` expressions below are literal text read out of action.yml, never meant to
# expand, so single-quoting them is the point.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# The runner's global git config signs commits and may name an identity: neither belongs here.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

US=$'\x1f'

LCOV_STEP='Generate head coverage report (lcov)'
CODECOV_STEP='Generate codecov.json'
SUMMARY_STEP='Build coverage summary'
GATE_STEP='Enforce line-coverage gate'
RECOMPUTE_STEP='Compute baseline from merge-base (fallback)'

# What the scripts read from the environment besides the filter: the inputs reach them as
# variables, not as expressions. `REPORT`'s basename is what the recompute step names its
# report; the rest are read into arguments.
REPORT_IN='out/head.lcov'
FAIL_UNDER='55'
TEST_ARGS='--all-features'

# --- the stub cargo --------------------------------------------------------------------------
# Every call is logged as its arguments, each NUL-terminated, then `@@END@@`, so an argument
# with a newline or a space survives. The filter variable as the call sees it goes to a second
# log, `<unset>` when it is not in the environment. `report ... --output-path F` writes F, as
# cargo-llvm-cov does, for the recompute step that then rewrites its paths; everything else
# prints nothing.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/cargo" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\0' "$@"; printf '@@END@@\0'; } >>"$CARGO_LOG"
printf '%s\0' "${LLVM_COV_IGNORE_FILENAME_REGEX-<unset>}" >>"$CARGO_LOG.seen"
prev=''
for a in "$@"; do
  if [ "$prev" = --output-path ]; then
    printf 'SF:%s/src/lib.rs\nDA:1,1\nend_of_record\n' "$PWD" >"$a"
  fi
  prev=$a
done
exit 0
EOF
chmod +x "$WORK/bin/cargo"

# parse_log <log>: sets
#   REPORT_COUNT      how many `cargo llvm-cov report` calls there were
#   REPORT_FLAGS      the arguments of those calls that start `--ignore-filename-regex`
#   REPORT_REST       the others, each preceded by a US (0x1f), after `llvm-cov report`
#   OTHER_WITH_FLAG   how many arguments of other cargo calls start `--ignore-filename-regex`
parse_log() {
  REPORT_COUNT=0
  REPORT_FLAGS=()
  REPORT_REST=''
  OTHER_WITH_FLAG=0
  local arg a args=()
  while IFS= read -r -d '' arg; do
    if [ "$arg" != '@@END@@' ]; then
      args+=("$arg")
      continue
    fi
    if [ "${args[0]:-}" = llvm-cov ] && [ "${args[1]:-}" = report ]; then
      REPORT_COUNT=$((REPORT_COUNT + 1))
      for a in "${args[@]:2}"; do
        case $a in
        --ignore-filename-regex*) REPORT_FLAGS+=("$a") ;;
        *) REPORT_REST+="$US$a" ;;
        esac
      done
    else
      for a in ${args[@]+"${args[@]}"}; do
        case $a in --ignore-filename-regex*) OTHER_WITH_FLAG=$((OTHER_WITH_FLAG + 1)) ;; esac
      done
    fi
    args=()
  done <"$1"
}

RUNS=0
# run_step <step name> <filter value>: runs the step's script, as `shell: bash` does, in a fresh
# workspace that is a git repository, with the filter in the environment. Sets RC and the
# parse_log variables. The workspace's sibling `base` is where the recompute puts its worktree.
run_step() {
  local name=$1 value=$2 dir ws script
  RUNS=$((RUNS + 1))
  dir="$WORK/run.$RUNS"
  ws="$dir/ws"
  mkdir -p "$ws"
  git init -q "$ws"
  git -C "$ws" config user.name test
  git -C "$ws" config user.email test@invalid
  git -C "$ws" config commit.gpgsign false
  git -C "$ws" commit -q --allow-empty -m base
  BASE_SHA="$(git -C "$ws" rev-parse HEAD)"
  RUN_DIR="$dir"
  RC=99
  script="$(step_run "$name")" || return 1
  printf '%s\n' "$script" >"$dir/step.sh"
  # The inputs reach a script through env:, so none holds an expression to fill in (and
  # tests/check-run-expressions.sh fails the build if one does).
  if grep -q '\${{' "$dir/step.sh"; then
    bad "'$name' holds an expression, and its inputs reach it through env:" "$(grep -n '\${{' "$dir/step.sh")"
    return 1
  fi
  : >"$dir/cargo.log"
  : >"$dir/cargo.log.seen"
  (
    cd "$ws" || exit 99
    env PATH="$WORK/bin:$PATH" CARGO_LOG="$dir/cargo.log" GITHUB_WORKSPACE="$ws" \
      GITHUB_OUTPUT="$dir/output" GITHUB_STEP_SUMMARY="$dir/summary" \
      REPORT="$REPORT_IN" FAIL_UNDER_LINES="$FAIL_UNDER" TEST_ARGS="$TEST_ARGS" \
      WORKTREE_SYSTEM_DEPS='' BASE_SHA="$BASE_SHA" \
      LLVM_COV_IGNORE_FILENAME_REGEX="$value" \
      bash --noprofile --norc -eo pipefail "$dir/step.sh"
  ) >"$dir/out" 2>&1
  RC=$?
  parse_log "$dir/cargo.log"
}

# --- the five steps, each with every kind of value ----------------------------------------------
STEP_NAMES=("$LCOV_STEP" "$CODECOV_STEP" "$SUMMARY_STEP" "$GATE_STEP" "$RECOMPUTE_STEP")
# What each `report` call is, apart from the filter (one argument per word).
STEP_REST=(
  "--lcov --output-path $REPORT_IN"
  "--codecov --output-path codecov.json"
  "--summary-only"
  "--summary-only --fail-under-lines $FAIL_UNDER"
  "--lcov --output-path $(basename "$REPORT_IN")"
)
# The values: a plain fragment, a leading `-` (the `*-sys` crates), regex specials, characters
# bash would reinterpret, a newline, and a comma (one regex, not a list).
VALUE_NAMES=(fragment leading-dash specials shell-characters newline comma)
VALUES=(
  'src/voice/backends/voxtral_mlx/'
  '-sys/'
  'src/ignored\.rs$|a(b|c)+[0-9]*'
  $'it\'s "q" $HOME `date` * ? \\ ; | & > <'
  $'a\nb'
  'a{1,3},b'
)

for i in "${!STEP_NAMES[@]}"; do
  name="${STEP_NAMES[$i]}"
  rest=" ${STEP_REST[$i]}"

  # Unset: the call is what it was before the input existed.
  run_step "$name" '' || continue
  got="rc=$RC reports=$REPORT_COUNT flags=${#REPORT_FLAGS[@]} rest=[${REPORT_REST//"$US"/ }] other=$OTHER_WITH_FLAG"
  eq "$name: with no filter, no flag reaches cargo" \
    "rc=0 reports=1 flags=0 rest=[$rest] other=0" "$got"

  for j in "${!VALUES[@]}"; do
    value="${VALUES[$j]}"
    run_step "$name" "$value" || continue
    got="rc=$RC reports=$REPORT_COUNT flags=${#REPORT_FLAGS[@]} flag=[${REPORT_FLAGS[0]:-}] rest=[${REPORT_REST//"$US"/ }] other=$OTHER_WITH_FLAG"
    eq "$name: a ${VALUE_NAMES[$j]} value arrives as one --ignore-filename-regex=<value>" \
      "rc=0 reports=1 flags=1 flag=[--ignore-filename-regex=$value] rest=[$rest] other=0" "$got"
  done
done

# The recompute step also has to have left a baseline where the diff reads it, with the
# worktree's paths rewritten to the workspace's: the flag must not have broken that.
run_step "$RECOMPUTE_STEP" 'src/gpu/' || true
ws="$RUN_DIR/ws"
eq "recompute with a filter: wrote the baseline under the report's basename" \
  "yes" "$([ -s "$ws/baseline/$(basename "$REPORT_IN")" ] && echo yes || echo no)"
has "recompute with a filter: its paths are the workspace's" \
  "$(cat "$ws/baseline/$(basename "$REPORT_IN")" 2>/dev/null)" "SF:$ws/src/lib.rs"
eq "recompute with a filter: said it recomputed" "recomputed=true" "$(cat "$RUN_DIR/output" 2>/dev/null)"
# The merge-base's own tests run in that worktree, and the step does not let them see the
# action's variables: the filter is copied into an argument first and then unset, as REPORT,
# TEST_ARGS and the rest are. Every cargo call the step made saw it unset.
eq "recompute with a filter: the merge-base's cargo calls do not see the filter variable" \
  "<unset>" "$(tr '\0' '\n' <"$RUN_DIR/cargo.log.seen" | sort -u)"
eq "recompute with a filter: and made the two calls" 2 \
  "$(tr -cd '\0' <"$RUN_DIR/cargo.log.seen" | wc -c | tr -d ' ')"

# --- which steps run `cargo llvm-cov report`, and how they get the value ----------------------
# Each step's whole block, not its `run:` (an inline `run:` has none to read), and without its
# full-line comments, since several steps explain the others in theirs. A `cargo llvm-cov` call
# is `cargo`, an optional `+toolchain`, then `llvm-cov`.
CARGO_LLVM_COV='cargo([[:space:]]+\+[^[:space:]]+)?[[:space:]]+llvm-cov'
report_steps=''
other_runs=''
while IFS= read -r line; do
  step="${line#    - name: }"
  code="$(step_block "$step" | grep -v '^[[:space:]]*#')" || {
    bad "read the step '$step'"
    continue
  }
  if grep -Eq "$CARGO_LLVM_COV([[:space:]]+[^[:space:]]+)*[[:space:]]+report([[:space:]]|\$)" <<<"$code"; then
    report_steps+="$step"$'\n'
  fi
  # Any other call: it must not write a report (`--no-report` says it does not).
  while IFS= read -r call; do
    case "$call" in
    *show-env* | *clean* | *--no-report*) ;;
    *) other_runs+="$step: ${call#"${call%%[![:space:]]*}"}"$'\n' ;;
    esac
  done < <(grep -E "$CARGO_LLVM_COV" <<<"$code" | grep -Ev "$CARGO_LLVM_COV([[:space:]]+[^[:space:]]+)*[[:space:]]+report([[:space:]]|\$)")
done < <(grep -E '^    - name: ' "$ACTION")
expected_steps="$(printf '%s\n' "${STEP_NAMES[@]}" | sort)"
eq "the steps that run 'cargo llvm-cov report' are the five this test runs" \
  "$expected_steps" "$(printf '%s' "$report_steps" | sort)"
eq "no other cargo llvm-cov call is one that could write a report" "" "$other_runs"

for name in "${STEP_NAMES[@]}"; do
  block="$(step_block "$name")" || continue
  has "$name: gets the input through env:" "$block" \
    '        LLVM_COV_IGNORE_FILENAME_REGEX: ${{ inputs.llvm-cov-ignore-filename-regex }}'
  lacks "$name: the script does not interpolate the input" "$(step_run "$name")" \
    'inputs.llvm-cov-ignore-filename-regex'
  # Fat mode only: thin mode has no profile for cargo-llvm-cov to report on.
  eq "$name: runs in fat mode only" 1 \
    "$(grep -cE "^      if: .*inputs\.run-coverage == 'true'" <<<"$block")"
done
# Five wirings and nowhere else: not omni-dev's diffs (their filter is `ignore-filename-regex`,
# a different syntax and a different path), and not a step that would then read it in thin mode.
eq "the input is read in those five steps and no other" 5 \
  "$(grep -cF 'inputs.llvm-cov-ignore-filename-regex' "$ACTION")"

# --- the input -----------------------------------------------------------------------------
input="$(input_block llvm-cov-ignore-filename-regex)" || exit 1
has "the input defaults to empty, which disables it" "$input" "default: ''"
has "the input is optional" "$input" 'required: false'
has "the input says it is fat mode only" "$input" 'Fat mode only'
has "the input says it is not omni-dev's filter" "$input" 'ONE regex'
has "the other filter's input points at this one" "$(input_block ignore-filename-regex)" \
  '`llvm-cov-ignore-filename-regex`'

summary
