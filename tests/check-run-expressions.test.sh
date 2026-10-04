#!/usr/bin/env bash
# Tests for tests/check-run-expressions.sh. Plain bash, no framework:
#   tests/check-run-expressions.test.sh
# Exits non-zero if any case fails.
#
# What matters most is that the check cannot pass when it should not: it has to find an
# expression in every shape a `run:` body takes (a block scalar, an inline value, a
# comment, after a blank line), name the line and the step, leave the places an expression
# belongs alone (`env:`, `if:`, `with:`), and still find one in the real action.yml (a
# mutated copy), where a restructure of the file would otherwise leave a check that passes
# on fixtures and finds nothing in practice.
# The ${{ }} patterns in the fixtures and the sed expressions below are literal text, not
# expansions.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/check-run-expressions.sh"
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

# runs <script> <file...>: runs a script, leaving its status in STATUS and its
# output (stdout and stderr together) in OUT.
runs() {
  local script=$1
  shift
  OUT="$(bash "$script" "$@" 2>&1)"
  STATUS=$?
}

# run <file...>: runs the script under test.
run() {
  runs "$SCRIPT" "$@"
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

# annotations <name> <want>: the last run printed <want> `::error file=` lines.
annotations() {
  local got
  got="$(grep -c '^::error file=' <<<"$OUT" || true)"
  if [ "$got" -eq "$2" ]; then ok "$1"; else bad "$1" "$got annotations, want $2: $OUT"; fi
}

# --- a block scalar ------------------------------------------------------------------

cat >"$WORK/block.yml" <<'EOF'
runs:
  steps:
    - name: Resolve it
      shell: bash
      run: |
        VERSION="${{ inputs.version }}"
        echo "$VERSION"
EOF
run "$WORK/block.yml"
status_is "block scalar: fails" 1
has "block scalar: names the file and the line" "file=$WORK/block.yml,line=6,"
has "block scalar: names the expression" "'\${{ inputs.version }}'"
has "block scalar: names the step" "(step 'Resolve it')"
has "block scalar: says what to do" "pass it through env:"
has "block scalar: shows the line" 'VERSION="${{ inputs.version }}"'
annotations "block scalar: one annotation" 1

# --- every spelling of the key and of the scalar header -----------------------------------

for header in '|' '|-' '|+' '>' '>-' '| # a comment'; do
  printf '    - name: S\n      run: %s\n        echo "${{ x }}"\n' "$header" >"$WORK/header.yml"
  run "$WORK/header.yml"
  status_is "header 'run: $header': fails" 1
  has "header 'run: $header': names the line after it" "line=3,"
done

cat >"$WORK/listitem.yml" <<'EOF'
steps:
  - run: |
      echo "${{ x }}"
  - name: Next
    run: echo fine
EOF
run "$WORK/listitem.yml"
status_is "- run: list item: fails" 1
has "- run: list item: names the line" "line=3,"
annotations "- run: list item: only that line" 1

cat >"$WORK/inline.yml" <<'EOF'
steps:
  - name: Inline
    run: echo "${{ inputs.report }}"
EOF
run "$WORK/inline.yml"
status_is "inline value: fails" 1
has "inline value: names the line of the key" "line=3,"
has "inline value: names the step" "(step 'Inline')"

cat >"$WORK/folded-plain.yml" <<'EOF'
steps:
  - name: Plain
    run: echo one
      and "${{ x }}"
EOF
run "$WORK/folded-plain.yml"
status_is "a plain value continued on the next line: fails" 1
has "a plain value continued on the next line: names that line" "line=4,"

# --- what inside a body counts -------------------------------------------------------------

# The runner evaluates an expression in a comment or a message too (#37), so nothing in a
# body is skipped, unlike check-deprecated-flags.sh which skips full-line comments.
cat >"$WORK/comment.yml" <<'EOF'
steps:
  - name: Commented
    run: |
      # The runner would replace ${{ inputs.version }} here.
      echo "ok"
EOF
run "$WORK/comment.yml"
status_is "an expression in a shell comment: fails" 1
has "an expression in a shell comment: names the line" "line=4,"

cat >"$WORK/message.yml" <<'EOF'
steps:
  - name: Message
    run: |
      echo "::error::bad value ${{ inputs.version }}"
EOF
run "$WORK/message.yml"
status_is "an expression in a message: fails" 1

cat >"$WORK/blank.yml" <<'EOF'
steps:
  - name: Blank
    run: |
      echo one

      echo "${{ x }}"
EOF
run "$WORK/blank.yml"
status_is "after a blank line inside the body: fails" 1
has "after a blank line inside the body: names the line" "line=6,"

cat >"$WORK/several.yml" <<'EOF'
steps:
  - name: Several
    run: |
      a="${{ inputs.one }}" b="${{inputs.two}}"
      c="${{ steps.x.outputs.y }}"
EOF
run "$WORK/several.yml"
status_is "several expressions: fails" 1
annotations "several expressions: one annotation each, two on one line" 3
has "several expressions: the first of a line" "'\${{ inputs.one }}'"
has "several expressions: the second of a line, trimmed" "'\${{ inputs.two }}'"
has "several expressions: the next line" "'\${{ steps.x.outputs.y }}'"

# --- what is not a body: an expression is meant to be there -------------------------------

cat >"$WORK/elsewhere.yml" <<'EOF'
inputs:
  github-token:
    default: ${{ github.token }}
runs:
  steps:
    - name: ${{ inputs.label }}
      if: github.event_name == 'pull_request' && ${{ inputs.x }}
      shell: bash
      env:
        VERSION: ${{ inputs.version }}
        REPORT: ${{ inputs.report }}
      run: |
        echo "$VERSION" "$REPORT"
    # a comment between steps: ${{ nope }}
    - name: Next
      uses: actions/cache@v4
      with:
        key: ${{ inputs.cache-prefix }}-${{ runner.os }}
      shell: bash
      run: echo done
EOF
run "$WORK/elsewhere.yml"
status_is "if, with, env, default, name and comments between steps: pass" 0
has "pass: says what was scanned" "$WORK/elsewhere.yml"

# The body ends where the key's siblings begin: a `shell:` key after it is not part of it.
cat >"$WORK/after.yml" <<'EOF'
steps:
  - name: One
    run: |
      echo one
    shell: bash
    env:
      X: ${{ inputs.x }}
  - name: Two
    run: |
      echo two
EOF
run "$WORK/after.yml"
status_is "keys after the body: pass" 0

# A `run:` key counts wherever it is, even as an input of an action under `with:`. That is
# the safe direction for a line scan: it is loud when it is wrong, and a miss would be silent.
cat >"$WORK/with-run.yml" <<'EOF'
steps:
  - name: Uses an action with a run input
    uses: some/action@v1
    with:
      run: ${{ inputs.command }}
EOF
run "$WORK/with-run.yml"
status_is "a run: key under with: is scanned too (conservative)" 1

# --- several steps, several files ----------------------------------------------------------

cat >"$WORK/two.yml" <<'EOF'
steps:
  - name: 'First step'
    run: echo "${{ a }}"
  - name: "Second step"
    run: |
      echo ok
  - name: Third
    run: |
      echo "${{ c }}"
EOF
printf 'steps:\n  - name: Other\n    run: |\n      x\n      ${{ d }}\n' >"$WORK/second.yml"
run "$WORK/two.yml" "$WORK/second.yml"
status_is "several files: fails" 1
annotations "several files: three findings" 3
has "several files: the first" "file=$WORK/two.yml,line=3,"
has "several files: a quoted step name is shown without its quotes" "(step 'First step')"
has "several files: the third step is the one named for its line" "line=9,title=Expression in a run: body::'\${{ c }}' is replaced by the runner before the shell parses the script (step 'Third')"
has "several files: line numbers restart in the next file" "file=$WORK/second.yml,line=5,"
lacks "several files: a clean step is not reported" "line=6,"

printf 'steps:\n  - run: echo "${{ x }}"\n' >"$WORK/unnamed.yml"
run "$WORK/unnamed.yml"
status_is "a step with no name: fails" 1
lacks "a step with no name: no step is named" "(step"

# --- a missing file is an error, not a pass ------------------------------------------------

run "$WORK/no-such-file.yml"
status_is "missing file: exit 2, not a pass" 2
has "missing file: says which" "no such file: $WORK/no-such-file.yml"

run "$WORK/elsewhere.yml" "$WORK/no-such-file.yml"
status_is "one missing file among good ones: exit 2" 2

# --- the allowlist is the extension point, and only shrinks -------------------------------

# variant <name> <line>: writes $WORK/<name>.sh, a copy of the script with <line> added
# right after the ALLOWED array opens (the first line that is just `ALLOWED=(`).
variant() {
  awk -v add="$2" '{ print } !done && $0 == "ALLOWED=(" { print add; done = 1 }' "$SCRIPT" >"$WORK/$1.sh"
  grep -qF -- "$2" "$WORK/$1.sh" || bad "variant $1 was built" "no line of the script is just 'ALLOWED=('"
}

cat >"$WORK/shell-input.yml" <<'EOF'
steps:
  - name: Setup commands
    run: |
      ${{ inputs.setup-commands }}
EOF

variant allowed "  'Setup commands|inputs.setup-commands|meant to be shell'"
runs "$WORK/allowed.sh" "$WORK/shell-input.yml"
status_is "an allowlisted expression in its step: passes" 0
annotations "an allowlisted expression in its step: nothing reported" 0

# The same expression in another step, another expression in that step, and another file
# with the step under a different name are all findings: the entry is that one pair.
sed 's/^  - name: Setup commands/  - name: Other step/' "$WORK/shell-input.yml" >"$WORK/other-step.yml"
runs "$WORK/allowed.sh" "$WORK/other-step.yml"
status_is "the allowlisted expression in another step: fails" 1
has "the allowlisted expression in another step: reported" "(step 'Other step')"
has "the allowlisted expression in another step: the entry is stale there" "ALLOWED entry 'Setup commands' for 'inputs.setup-commands' matches no expression"

sed 's/inputs.setup-commands/inputs.test-args/' "$WORK/shell-input.yml" >"$WORK/other-expr.yml"
runs "$WORK/allowed.sh" "$WORK/other-expr.yml"
status_is "another expression in the allowlisted step: fails" 1
has "another expression in the allowlisted step: reported" "'\${{ inputs.test-args }}'"

# A second expression beside the allowed one in the same step is still found.
cat >"$WORK/both.yml" <<'EOF'
steps:
  - name: Setup commands
    run: |
      ${{ inputs.setup-commands }}
      cargo test ${{ inputs.test-args }}
EOF
runs "$WORK/allowed.sh" "$WORK/both.yml"
status_is "an allowed and a new expression in one step: fails" 1
annotations "an allowed and a new expression in one step: only the new one" 1
has "an allowed and a new expression in one step: the new one" "'\${{ inputs.test-args }}'"

# An entry that matches nothing fails, so the list can only shrink.
runs "$WORK/allowed.sh" "$WORK/elsewhere.yml"
status_is "an entry that matches nothing: fails" 1
has "an entry that matches nothing: names it" "ALLOWED entry 'Setup commands' for 'inputs.setup-commands' matches no expression"
has "an entry that matches nothing: says to remove it" "Remove it"
annotations "an entry that matches nothing: no finding in the file itself" 0

# Two entries, one used and one not: only the unused one is named.
variant two "  'Other|inputs.gone|was removed'"
variant_two_line="  'Setup commands|inputs.setup-commands|meant to be shell'"
awk -v add="$variant_two_line" '{ print } !done && $0 == "ALLOWED=(" { print add; done = 1 }' "$WORK/two.sh" >"$WORK/two-entries.sh"
runs "$WORK/two-entries.sh" "$WORK/shell-input.yml"
status_is "two entries, one unused: fails" 1
has "two entries, one unused: names the unused one" "ALLOWED entry 'Other' for 'inputs.gone'"
lacks "two entries, one unused: not the used one" "ALLOWED entry 'Setup commands'"

# An entry that is not 'step|expression|reason' would match wrongly or nothing at all.
for entry in 'a|b' 'a|b|' 'a||c' '|b|c' 'abc' '||'; do
  variant refused "  '$entry'"
  runs "$WORK/refused.sh" "$WORK/elsewhere.yml"
  status_is "allowlist entry '$entry': refused with exit 2" 2
  has "allowlist entry '$entry': says why" "is not 'step name|expression|reason'"
done

# --- the real file -------------------------------------------------------------------------

# No arguments: the file and the directory the workflow runs it on, from any cwd.
OUT="$(cd "$WORK" && bash "$SCRIPT" 2>&1)"
STATUS=$?
status_is "default scan of the repository passes" 0
has "default scan: covers action.yml" "action.yml"

# The same check must find expressions in the real action.yml. Putting them back at the
# call sites is what a regression would look like. Each copy must differ, or a reworded
# call site would leave this passing for nothing.
# mutate <name> <sed expression>: writes $WORK/<name>.yml from action.yml, runs the check
# on it, and expects one annotation per line the rewrite changed.
mutate() {
  sed -e "$2" "$ROOT/action.yml" >"$WORK/$1.yml"
  if cmp -s "$ROOT/action.yml" "$WORK/$1.yml"; then
    bad "mutation $1: action.yml has call sites to rewrite" "the rewrite changed nothing"
    return
  fi
  ok "mutation $1: action.yml has call sites to rewrite"
  run "$WORK/$1.yml"
  status_is "mutation $1: action.yml with an expression put back fails" 1
  # Counted from the diff, not by grepping for the expression, so a line that is rightly
  # not a body (an `env:` entry) does not change what this expects.
  local want got
  want="$(diff "$ROOT/action.yml" "$WORK/$1.yml" | grep -c '^>')"
  got="$(grep -c '^::error file=' <<<"$OUT")"
  if [ "$want" -gt 0 ] && [ "$got" -eq "$want" ]; then
    ok "mutation $1: every rewritten call site is reported ($got)"
  else
    bad "mutation $1: every rewritten call site is reported" "$got annotations for $want lines: $OUT"
  fi
}

mutate report 's/"\$REPORT"/"${{ inputs.report }}"/g'
mutate shell-input 's/eval "\$SETUP_COMMANDS"/${{ inputs.setup-commands }}/'
mutate platform 's/^        # A binary that cannot be had/        # A binary that cannot be had ${{ runner.os }}/'
has "mutation platform: a comment in a body is found, and the step is named" "(step 'Determine platform and download URL')"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
