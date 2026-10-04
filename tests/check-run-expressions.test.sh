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

# A step is the nearest list item above the key: one that starts with another key, or has
# no name, is not the previous step, so an allowlist entry cannot leak onto it.
cat >"$WORK/attribution.yml" <<'EOF'
steps:
  - name: First
    run: echo "${{ a }}"
  - id: second
    run: |
      echo "${{ b }}"
  - uses: some/action@v1
    with:
      paths:
        - one
        - name: nested
      key: v
  - id: fourth
    name: Fourth step
    run: echo "${{ d }}"
  - id: fifth
    with:
      name: not-the-step-name
    run: echo "${{ e }}"
EOF
run "$WORK/attribution.yml"
status_is "attribution: fails" 1
annotations "attribution: four findings" 4
has "attribution: the named step is named" "line=3,title=Expression in a run: body::'\${{ a }}' is replaced by the runner before the shell parses the script (step 'First')"
lacks "attribution: a step starting with another key is not the previous step" "'\${{ b }}' is replaced by the runner before the shell parses the script (step"
has "attribution: a name: key later in the step names it" "'\${{ d }}' is replaced by the runner before the shell parses the script (step 'Fourth step')"
lacks "attribution: a name: under with: does not name the step" "'\${{ e }}' is replaced by the runner before the shell parses the script (step"

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

variant allowed "  'Setup commands :: inputs.setup-commands :: meant to be shell'"
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
variant two "  'Other :: inputs.gone :: was removed'"
variant_two_line="  'Setup commands :: inputs.setup-commands :: meant to be shell'"
awk -v add="$variant_two_line" '{ print } !done && $0 == "ALLOWED=(" { print add; done = 1 }' "$WORK/two.sh" >"$WORK/two-entries.sh"
runs "$WORK/two-entries.sh" "$WORK/shell-input.yml"
status_is "two entries, one unused: fails" 1
has "two entries, one unused: names the unused one" "ALLOWED entry 'Other' for 'inputs.gone'"
lacks "two entries, one unused: not the used one" "ALLOWED entry 'Setup commands'"

# An entry that is not 'step :: expression :: reason' would match wrongly or nothing at all.
# The last one is the old '|' form, which would read as a step name with no separator.
for entry in 'abc' 'a :: b' 'a :: b :: ' ' :: b :: c' 'a ::  :: c' 'a|b|c'; do
  variant refused "  '$entry'"
  runs "$WORK/refused.sh" "$WORK/elsewhere.yml"
  status_is "allowlist entry '$entry': refused with exit 2" 2
  has "allowlist entry '$entry': says why" "is not 'step name :: expression :: reason'"
done

# An expression with '||' in it is the common shape, and why the separator is not '|'. The
# reason may hold the separator.
cat >"$WORK/or.yml" <<'EOF'
steps:
  - name: Either
    run: |
      echo "${{ inputs.a || inputs.b }}"
EOF
variant either "  'Either :: inputs.a || inputs.b :: either one :: or both'"
runs "$WORK/either.sh" "$WORK/or.yml"
status_is "an allowlisted expression holding '||': passes" 0
annotations "an allowlisted expression holding '||': nothing reported" 0
run "$WORK/or.yml"
status_is "the same without the entry: fails" 1
has "the same without the entry: names the whole expression" "'\${{ inputs.a || inputs.b }}'"

# --- the workflows (#73) -------------------------------------------------------------------

# test.yml runs the check over every workflow of the repository (both extensions GitHub
# reads) as well as action.yml. They hold the steps one level deeper than action.yml does,
# and lists of their own ahead of the steps (a `schedule:` entry, a `paths:` filter), so
# what matters is that an expression in one of THEIR `run:` bodies is found, with the line
# and the step named. Both are read out of the workflow, so an edit to it does not break
# the case; the workflow as committed is the control that must pass.
workflows=()
for workflow in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  [ ! -f "$workflow" ] || workflows+=("$workflow")
done

planted_in=" "
for workflow in "${workflows[@]}"; do
  name="$(basename "$workflow")"
  run "$workflow"
  status_is "workflow $name: passes as committed" 0
  # <line of the first `run: |` key> <its column> <name of the step it belongs to>. A
  # workflow with no block body (commit-check.yml has no run: at all) gives nothing, and is
  # checked as committed only.
  plant="$(awk '
    BEGIN { SQ = sprintf("%c", 39) }
    /^[[:space:]]*-[[:space:]]+name:/ {
      step = $0
      sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", step)
      gsub("^[\"" SQ "]|[\"" SQ "]$", "", step)
    }
    /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*\|[[:space:]]*$/ {
      match($0, /run:/)
      print FNR "\t" RSTART - 1 "\t" step
      exit
    }' "$workflow")"
  [ -n "$plant" ] || continue
  IFS=$'\t' read -r plant_line plant_col plant_step <<<"$plant"
  if [ -z "$plant_step" ]; then
    bad "workflow $name: the first block run: body belongs to a named step" "found: '$plant'"
    continue
  fi
  planted_in+="$name "
  awk -v at="$plant_line" -v col="$plant_col" '
    { print }
    FNR == at { printf "%" (col + 2) "s%s\n", "", "echo \"${{ github.head_ref }}\"" }' "$workflow" >"$WORK/planted-$name"
  run "$WORK/planted-$name"
  status_is "workflow $name with an expression in a run: body: fails" 1
  has "workflow $name with an expression in a run: body: names the line after the key" "file=$WORK/planted-$name,line=$((plant_line + 1)),"
  has "workflow $name with an expression in a run: body: names the expression" "'\${{ github.head_ref }}'"
  has "workflow $name with an expression in a run: body: names the step" "(step '$plant_step')"
  annotations "workflow $name with an expression in a run: body: only the planted one" 1
done

# The three that hold block bodies must have been planted in, or a restructure of one would
# leave this section passing on the others.
for name in e2e-sharded.yml integration.yml pr-paths.yml; do
  case "$planted_in" in
    *" $name "*) ok "workflow $name: a block run: body was found to plant in" ;;
    *) bad "workflow $name: a block run: body was found to plant in" "planted in:$planted_in" ;;
  esac
done

# A list ahead of the steps whose dash is shallower than the steps' own must not stay "the
# step": integration.yml's weekly `schedule:` entry sits at column 4 and its steps at column
# 6, and with the entry taken for a step none of the 26 findings planted in that file had a
# step name. The `paths:` list of pr-paths.yml (dash at column 6) never showed it.
cat >"$WORK/shallow-list.yml" <<'EOF'
on:
  schedule:
    - cron: '17 6 * * 1'
  workflow_dispatch:
jobs:
  j:
    steps:
      - name: After the list
        run: |
          echo "${{ x }}"
EOF
run "$WORK/shallow-list.yml"
status_is "a list with a shallower dash ahead of the steps: fails" 1
has "a list with a shallower dash ahead of the steps: the step is still named" "(step 'After the list')"

# Same file with the steps' dash as shallow as the list's: the control that always worked.
sed -e 's/^    - cron/      - cron/' "$WORK/shallow-list.yml" >"$WORK/level-list.yml"
run "$WORK/level-list.yml"
has "a list with the steps' own dash ahead of them: the step is named" "(step 'After the list')"

# What runs the check names both extensions GitHub reads for a workflow, and nullglob keeps
# the one with no file from reaching the check as a path that does not exist.
if grep -qF 'bash tests/check-run-expressions.sh action.yml .github/workflows/*.yml .github/workflows/*.yaml' "$ROOT/.github/workflows/test.yml"; then
  ok "test.yml scans action.yml and both workflow extensions"
else
  bad "test.yml scans action.yml and both workflow extensions" "no line runs the check over action.yml, *.yml and *.yaml"
fi
if grep -qF 'shopt -s nullglob' "$ROOT/.github/workflows/test.yml"; then
  ok "test.yml lets a glob with no match vanish"
else
  bad "test.yml lets a glob with no match vanish" "no 'shopt -s nullglob'"
fi

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
mutate shell-input 's/eval "\$commands"/${{ inputs.setup-commands }}/'
mutate platform 's/^        # A binary that cannot be had/        # A binary that cannot be had ${{ runner.os }}/'
has "mutation platform: a comment in a body is found, and the step is named" "(step 'Determine platform and download URL')"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
