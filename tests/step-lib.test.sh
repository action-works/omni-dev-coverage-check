#!/usr/bin/env bash
# Tests for tests/step-lib.sh. Plain bash, no framework:
#   tests/step-lib.test.sh
# Exits non-zero if any case fails.
#
# The readers take their text from action.yml's layout, so what matters most is what they
# do outside it: refuse, rather than hand a test an empty script or another step's. Each
# refusal here has a control that differs in one line and must be read. The fixtures are
# small files written per case, because the real action.yml has none of these layouts; the
# last cases run the readers over the real file, which only has to be read or refused.

# The $VAR and ${{ }} patterns in the fixtures and the expectations are literal text.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# yaml <name>: writes stdin to $WORK/<name>.yml, which the readers then read.
yaml() {
  ACTION="$WORK/$1.yml"
  cat >"$ACTION"
}

# read_with <reader> <argument...>: calls the reader. Leaves its status in STATUS, what it printed
# in OUT and what it said on stderr in ERR.
read_with() {
  OUT="$("$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(<"$WORK/err")"
}

# is_read <name> <expected>: the last call read the block: status 0, nothing on stderr,
# and exactly <expected> on stdout (as `$(...)` gives it, so trailing newlines do not count).
is_read() {
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] && [ "$OUT" = "$2" ]; then
    ok "$1"
  else
    bad "$1" "exit $STATUS, stderr '$ERR', stdout '$OUT'; wanted exit 0, no stderr, stdout '$2'"
  fi
}

# is_refused <name> <fragment>: the last call refused: status 1, nothing on stdout, and
# the reason on stderr, holding <fragment>.
is_refused() {
  if [ "$STATUS" -eq 1 ] && [ -z "$OUT" ] && [[ "$ERR" == *"$2"* ]]; then
    ok "$1"
  else
    bad "$1" "exit $STATUS, stdout '$OUT', stderr '$ERR'; wanted exit 1, no stdout, stderr holding '$2'"
  fi
}

# --- step_run: what it reads -----------------------------------------------------------

yaml basic <<'EOF'
runs:
  using: composite
  steps:
    - name: Alpha
      shell: bash
      run: |
        echo one
        echo two
EOF
read_with step_run Alpha
is_read "step_run: a body that ends at the end of the file" $'echo one\necho two'

# The same file with no newline after its last line, as an editor may leave it.
printf 'runs:\n  steps:\n    - name: Alpha\n      run: |\n        echo one\n        echo last' >"$WORK/no-eol.yml"
ACTION="$WORK/no-eol.yml"
read_with step_run Alpha
is_read "step_run: a last line with no newline is still read" $'echo one\necho last'

yaml straight-after <<'EOF'
runs:
  steps:
    - name: Alpha
      shell: bash
      run: |
        echo alpha
    - name: Beta
      shell: bash
      run: |
        echo beta
EOF
read_with step_run Alpha
is_read "step_run: the next step starts straight after, and is not read" "echo alpha"
read_with step_run Beta
is_read "step_run: and the next one is read as its own" "echo beta"

yaml keys-around <<'EOF'
runs:
  steps:
    - name: Alpha
      if: github.event_name == 'push'
      env:
        run: not-the-script
      shell: bash
      run: |
        echo alpha
      working-directory: sub
    - name: Beta
      run: |
        echo beta
EOF
read_with step_run Alpha
is_read "step_run: keys before and after run: are not part of it, nor is a nested run:" "echo alpha"

yaml indents <<'EOF'
runs:
  steps:
    - name: Alpha
      shell: bash
      run: |
        if true; then
          echo deeper
        fi
        # a comment in the script
        echo done
      # a comment after the script
EOF
read_with step_run Alpha
is_read "step_run: deeper lines keep their extra indent, and a comment in the body is the body's" \
  $'if true; then\n  echo deeper\nfi\n# a comment in the script\necho done'

printf 'runs:\n  steps:\n    - name: Alpha\n      run: |\n        echo a\n\n   \n        echo b\n    - name: Beta\n      run: |\n        echo beta\n' >"$WORK/blank.yml"
ACTION="$WORK/blank.yml"
read_with step_run Alpha
is_read "step_run: a blank line and a whitespace-only line do not end the body" $'echo a\n\n\necho b'

# Past the body's indent, spaces are the line's own, as YAML reads them.
printf 'runs:\n  steps:\n    - name: Alpha\n      run: |\n        echo a\n            \n        echo b\n' >"$WORK/blank-long.yml"
ACTION="$WORK/blank-long.yml"
read_with step_run Alpha
is_read "step_run: a whitespace-only line longer than the indent keeps the spaces past it" $'echo a\n    \necho b'

for style in '|' '|-' '|+'; do
  yaml "style" <<EOF
runs:
  steps:
    - name: Alpha
      run: $style
        echo styled
EOF
  read_with step_run Alpha
  is_read "step_run: run: $style is a literal block" "echo styled"
done

yaml prefix <<'EOF'
runs:
  steps:
    - name: Build docs
      run: |
        echo docs
    - name: Build
      run: |
        echo build
EOF
read_with step_run Build
is_read "step_run: a name that starts another step's name reads its own" "echo build"

# --- step_run: what it refuses -----------------------------------------------------------

yaml missing <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |
        echo alpha
EOF
read_with step_run Gamma
is_refused "step_run: a step that is not there" 'no step named "Gamma"'
read_with step_run Alph
is_refused "  and a name that is only the start of one" 'no step named "Alph"'
read_with step_run Alpha
is_read "  (control: the step that is there)" "echo alpha"

yaml twice <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |
        echo first
    - name: Alpha
      run: |
        echo second
EOF
read_with step_run Alpha
is_refused "step_run: two steps of one name is not read as the first" '2 steps named "Alpha"'

yaml two-spaces <<'EOF'
runs:
  steps:
  - name: Alpha
    run: |
      echo alpha
EOF
read_with step_run Alpha
is_refused "step_run: steps at another indent are not found" 'no step named "Alpha"'

yaml no-run-then-named <<'EOF'
runs:
  steps:
    - name: Alpha
      uses: actions/checkout@v4
    - name: Beta
      shell: bash
      run: |
        echo beta
EOF
read_with step_run Alpha
is_refused "step_run: a step with no run:, ahead of a named step that has one" "has no run:"
read_with step_run Beta
is_read "  (control: that next step)" "echo beta"

yaml no-run-then-unnamed <<'EOF'
runs:
  steps:
    - name: Alpha
      uses: actions/checkout@v4
    - shell: bash
      run: |
        echo the unnamed step
EOF
read_with step_run Alpha
is_refused "step_run: a step with no run:, ahead of an UNNAMED step that has one" "has no run:"

yaml no-run-last <<'EOF'
runs:
  steps:
    - name: Alpha
      uses: actions/checkout@v4
      with:
        run: |
          not a step script
EOF
read_with step_run Alpha
is_refused "step_run: the last step, with a run: only under another key" "has no run:"

yaml no-run-then-key <<'EOF'
runs:
  steps:
    - name: Alpha
      uses: actions/checkout@v4
branding:
  color: blue
EOF
read_with step_run Alpha
is_refused "step_run: the last step, with a key after the list and no run:" "has no run:"

yaml inline <<'EOF'
runs:
  steps:
    - name: Alpha
      shell: bash
      run: omni-dev --version
EOF
read_with step_run Alpha
is_refused "step_run: an inline run: is not a block" "run: is not a literal block"
has "  and shows the line it saw" "$ERR" "run: omni-dev --version"

for style in '>' '>-' '|2' '|-2' '| # why' '"|"'; do
  yaml style <<EOF
runs:
  steps:
    - name: Alpha
      run: $style
        echo styled
EOF
  read_with step_run Alpha
  is_refused "step_run: run: $style is not read as a literal block" "run: is not a literal block"
done

yaml ten <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |
          echo ten
EOF
read_with step_run Alpha
is_refused "step_run: a body indented 10 is not read as one indented 8" "indented 10 spaces"

yaml seven <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |
       echo seven
EOF
read_with step_run Alpha
is_refused "step_run: a body indented 7 is not read as one indented 8" "indented 7 spaces"

yaml empty-then-key <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |
      shell: bash
EOF
read_with step_run Alpha
is_refused "step_run: an empty body, with a key straight after" "run: block is empty"

yaml empty-then-step <<'EOF'
runs:
  steps:
    - name: Alpha
      run: |

    - name: Beta
      run: |
        echo beta
EOF
read_with step_run Alpha
is_refused "step_run: an empty body with a blank line, then the next step" "run: block is empty"

printf 'runs:\n  steps:\n    - name: Alpha\n      run: |\n' >"$WORK/empty-eof.yml"
ACTION="$WORK/empty-eof.yml"
read_with step_run Alpha
is_refused "step_run: an empty body at the end of the file" "run: block is empty"

# --- step_block ----------------------------------------------------------------------------

yaml blocks <<'EOF'
runs:
  steps:
    # ---------------------------------------------------------------------
    # The first group
    # ---------------------------------------------------------------------
    - name: Alpha
      id: alpha
      # A comment inside the step.
      shell: bash
      run: |
        echo alpha

        echo more
    # ---------------------------------------------------------------------
    # The second group
    # ---------------------------------------------------------------------
    - uses: actions/checkout@v4
    - name: Beta
      shell: bash
      run: |
        echo beta
branding:
  color: blue
EOF
read_with step_block Alpha
is_read "step_block: from the name line to the next step's banner, comments inside kept" \
  $'    - name: Alpha\n      id: alpha\n      # A comment inside the step.\n      shell: bash\n      run: |\n        echo alpha\n\n        echo more'
read_with step_block Beta
is_read "step_block: the last step stops at the key after the list" \
  $'    - name: Beta\n      shell: bash\n      run: |\n        echo beta'

yaml blocks-unnamed <<'EOF'
runs:
  steps:
    - name: Alpha
      uses: actions/checkout@v4
    - shell: bash
      run: |
        echo the unnamed step
EOF
read_with step_block Alpha
is_read "step_block: an unnamed step after is not part of this one" \
  $'    - name: Alpha\n      uses: actions/checkout@v4'

printf 'runs:\n  steps:\n    - name: Alpha\n      shell: bash' >"$WORK/block-eof.yml"
ACTION="$WORK/block-eof.yml"
read_with step_block Alpha
is_read "step_block: a step that ends at the end of the file, with no newline" \
  $'    - name: Alpha\n      shell: bash'

read_with step_block Gamma
is_refused "step_block: a step that is not there" 'no step named "Gamma"'
ACTION="$WORK/twice.yml"
read_with step_block Alpha
is_refused "step_block: two steps of one name" '2 steps named "Alpha"'
ACTION="$WORK/two-spaces.yml"
read_with step_block Alpha
is_refused "step_block: steps at another indent are not found" 'no step named "Alpha"'

# --- step_field ----------------------------------------------------------------------------

yaml fields <<'EOF'
runs:
  steps:
    - name: Alpha
      id: alpha-id
      if: github.event_name == 'pull_request' && steps.x.outputs.y == 'true'
      uses: dawidd6/action-download-artifact@v27
      with:
        id: not-the-step-id
        name: ${{ inputs.name }}
      shell: bash
      ifx: not-the-if
      run: bash "$ACTION_PATH/scripts/x.sh"
    - name: Beta
      uses: actions/cache@v4
      shell: bash
EOF
read_with step_field Alpha id
is_read "step_field: a key of the step, at its own indent, not the nested one of the same name" "alpha-id"
read_with step_field Alpha if
is_read "step_field: an expression and quotes, as written" "github.event_name == 'pull_request' && steps.x.outputs.y == 'true'"
read_with step_field Alpha uses
is_read "step_field: uses" "dawidd6/action-download-artifact@v27"
read_with step_field Alpha run
is_read "step_field: an inline run, with its quotes and variables as written" 'bash "$ACTION_PATH/scripts/x.sh"'
read_with step_field Beta shell
is_read "step_field: the next step's own key" "bash"
read_with step_field Beta id
is_refused "step_field: a key only the next step has is not read for this one" 'has no "id:" at 6 spaces'
read_with step_field Beta uses
is_read "step_field: and a key it shares with the one before is its own" "actions/cache@v4"

read_with step_field Alpha nope
is_refused "step_field: a key the step does not have" 'has no "nope:" at 6 spaces'
read_with step_field Alpha name
is_refused "step_field: name is the step's heading, not a key at 6 spaces" 'has no "name:" at 6 spaces'
read_with step_field Alpha with
is_refused "step_field: a map has no value on its line" '"with:" has no value on its line'
read_with step_field Alpha i
is_refused "step_field: a key is matched whole, not by its start" 'has no "i:" at 6 spaces'

printf 'runs:\n  steps:\n    - name: Alpha\n      id: last-no-newline' >"$WORK/field-eof.yml"
ACTION="$WORK/field-eof.yml"
read_with step_field Alpha id
is_read "step_field: a last line with no newline" "last-no-newline"
yaml field-blank <<'EOF'
runs:
  steps:
    - name: Alpha
      id:
      shell: bash
EOF
read_with step_field Alpha id
is_refused "step_field: a key with nothing after it is refused, not read as empty" '"id:" has no value on its line'
read_with step_field Alpha shell
is_read "step_field: its control, the next key, is read" "bash"

ACTION="$WORK/fields.yml"
read_with step_field Gamma id
is_refused "step_field: a step that is not there" 'no step named "Gamma"'
ACTION="$WORK/twice.yml"
read_with step_field Alpha id
is_refused "step_field: two steps of one name" '2 steps named "Alpha"'
ACTION="$WORK/two-spaces.yml"
read_with step_field Alpha id
is_refused "step_field: steps at another indent are not found" 'no step named "Alpha"'
ACTION="$WORK/missing-file.yml"
read_with step_field Alpha id
is_refused "step_field: a file that is not there" "ACTION must name the file to read"
ACTION=""
read_with step_field Alpha id
is_refused "step_field: ACTION unset" "ACTION must name the file to read"

# --- step_map ------------------------------------------------------------------------------

yaml maps <<'EOF'
runs:
  steps:
    - name: Alpha
      id: alpha
      env:
        GH_TOKEN: ${{ github.token }}
        # a comment between entries

        BASE_REF: ${{ steps.mb.outputs.sha }}
        DEPTH: ${{ inputs.baseline-ancestor-depth }}
      with:
        run_id: ${{ steps.lookup.outputs.run-id }}
        name: ${{ inputs.baseline-artifact-name }}
      shell: bash
      run: |
        echo alpha
    - name: Beta
      env:
        ONLY: one
    - name: Gamma
      with:
        path: |
          coverage.json
          summary.txt
        name: after-a-block
    - name: Delta
      with:
        name: x
       odd: 7 spaces
    - name: Epsilon
      env:
      shell: bash
    - name: Zeta
      env: inline-value
EOF
read_with step_map Alpha env
is_read "step_map: the entries of env, dedented, in order, as written; comment and blank skipped" \
  $'GH_TOKEN: ${{ github.token }}\nBASE_REF: ${{ steps.mb.outputs.sha }}\nDEPTH: ${{ inputs.baseline-ancestor-depth }}'
read_with step_map Alpha with
is_read "step_map: the entries of with, up to the key after it" \
  $'run_id: ${{ steps.lookup.outputs.run-id }}\nname: ${{ inputs.baseline-artifact-name }}'
read_with step_map Beta env
is_read "step_map: the last entries of a step stop at the next step" "ONLY: one"

read_with step_map Beta with
is_refused "step_map: a map the step does not have" 'has no "with:" at 6 spaces'
read_with step_map Gamma env
is_refused "step_map: a map only another step has is not read for this one" 'has no "env:" at 6 spaces'
read_with step_map Zeta env
is_refused "step_map: a key with a value on its line is not a map" '"env:" has a value on its line, so it is not a map'
read_with step_map Epsilon env
is_refused "step_map: a map with no entries" '"env:" has no entries'
read_with step_map Gamma with
is_refused "step_map: an entry whose value goes on to deeper lines is refused, with the line" \
  'line 23 is indented 10 spaces, a value that goes on past its line'
read_with step_map Delta with
is_refused "step_map: an entry at another indent is refused, with the line" \
  'line 29 is indented 7 spaces, and this reads entries indented 8'
read_with step_map Alpha id
is_refused "step_map: a key with a value on its line is not a map, id" '"id:" has a value on its line'

ACTION="$WORK/maps.yml"
read_with step_map Nope env
is_refused "step_map: a step that is not there" 'no step named "Nope"'
ACTION="$WORK/twice.yml"
read_with step_map Alpha env
is_refused "step_map: two steps of one name" '2 steps named "Alpha"'
ACTION="$WORK/two-spaces.yml"
read_with step_map Alpha env
is_refused "step_map: steps at another indent are not found" 'no step named "Alpha"'
ACTION="$WORK/missing-file.yml"
read_with step_map Alpha env
is_refused "step_map: a file that is not there" "ACTION must name the file to read"
ACTION=""
read_with step_map Alpha env
is_refused "step_map: ACTION unset" "ACTION must name the file to read"

# --- input_block --------------------------------------------------------------------------

yaml inputs <<'EOF'
name: 'Example'
inputs:
  # ------------------------------------------------------------------
  # The first group
  # ------------------------------------------------------------------
  alpha:
    description: 'The first'
    required: false
    default: 'a'
  alpha-extra:
    description: >-
      Another, whose description
      runs over two lines
    required: true

  beta:
    description: 'The last'
outputs:
  gamma:
    description: 'An output, not an input'
  alpha:
    description: 'An output that shares the first input''s name'
runs:
  using: composite
EOF
read_with input_block alpha
is_read "input_block: an input's block, up to the next input" \
  $'  alpha:\n    description: \'The first\'\n    required: false\n    default: \'a\''
read_with input_block alpha-extra
is_read "input_block: a block that runs over lines, with a blank line after it" \
  $'  alpha-extra:\n    description: >-\n      Another, whose description\n      runs over two lines\n    required: true'
read_with input_block beta
is_read "input_block: the last input stops at the next section" $'  beta:\n    description: \'The last\''

read_with input_block gamma
is_refused "input_block: an output is not an input" 'no input named "gamma"'
read_with input_block delta
is_refused "input_block: an input that is not there" 'no input named "delta"'
read_with input_block alph
is_refused "  and a name that is only the start of one" 'no input named "alph"'

yaml comment-ends <<'EOF'
inputs:
  alpha:
    description: 'The first'
  # ------------------------------------------------------------------
  # A banner before the next group
  # ------------------------------------------------------------------
  beta:
    description: 'The second'
EOF
read_with input_block alpha
is_read "input_block: a comment at the inputs' indent ends the block" $'  alpha:\n    description: \'The first\''

# --- the file itself ----------------------------------------------------------------------

unset ACTION
read_with step_run Alpha
is_refused "step_run: no ACTION set" "ACTION must name the file"
read_with step_block Alpha
is_refused "step_block: no ACTION set" "ACTION must name the file"
read_with input_block alpha
is_refused "input_block: no ACTION set" "ACTION must name the file"

ACTION="$WORK/not-there.yml"
read_with step_run Alpha
is_refused "step_run: a file that is not there" "not a readable one"
read_with input_block alpha
is_refused "input_block: a file that is not there" "not a readable one"

ACTION=""
read_with step_run Alpha
is_refused "step_run: an empty ACTION" "ACTION must name the file"

# A name with a backslash is looked for as written, by grep and by awk alike.
yaml backslash <<'EOF'
runs:
  steps:
    - name: Match a\tb
      run: |
        echo matched
EOF
read_with step_run 'Match a\tb'
is_read "step_run: a backslash in the name is not an escape" "echo matched"

# --- the real action.yml ---------------------------------------------------------------

# Its steps are not any one layout, so no step is named here: each must be read whole or
# refused, never half-read. What each reader should reach is counted without the readers:
# a step whose `run:` is a literal block is read, so the count of those lines is the count
# of scripts read (every step here is named; an unnamed step with a block script would be
# counted and not read, which this would report). And a script's last line must be inside
# its step_block, so a block cut short before the script ends is caught.
ACTION="$ROOT/action.yml"
steps=0 read_steps=0 broken=""
while IFS= read -r name; do
  steps=$((steps + 1))
  read_with step_block "$name"
  block="$OUT"
  if [ "$STATUS" -ne 0 ] || [ "$(head -n1 <<<"$block")" != "    - name: $name" ]; then
    broken+=" [step_block $name]"
  fi
  read_with step_run "$name"
  if [ "$STATUS" -eq 0 ]; then
    read_steps=$((read_steps + 1))
    if [ -z "$OUT" ] || [ -n "$ERR" ]; then
      broken+=" [step_run read nothing: $name]"
    elif ! grep -qxF -- "        $(tail -n1 <<<"$OUT")" <<<"$block"; then
      broken+=" [step_block ends before the script does: $name]"
    fi
  elif [ -n "$OUT" ] || [ -z "$ERR" ]; then
    broken+=" [step_run refused unclearly: $name]"
  fi
done < <(sed -n 's/^    - name: //p' "$ACTION")
eq "action.yml: every step is read whole or refused cleanly" "" "$broken"
pass "action.yml: the file has steps to read" test "$steps" -gt 0
eq "action.yml: every step with a literal-block run: is read" \
  "$(grep -cE '^      run: [|][-+]? *$' "$ACTION")" "$read_steps"

# Every env: and with: map of the real file, found without the readers: the step's name, the
# key, and whether a line deeper than 8 spaces comes before the map ends. step_map reads the
# map whole, or refuses it exactly when it has such a line (the block `path:` of an upload
# step), and never prints half of one.
maps="$(awk '
  function indent(s) { match(s, /^ */); return RLENGTH }
  function flush() { if (inmap && name != "") print name "\t" key "\t" (deeper ? "deeper" : "ok"); inmap = 0 }
  /^    - / { flush(); name = $0; if (!sub(/^    - name: /, "", name)) name = ""; next }
  inmap && $0 !~ /^ *$/ && indent($0) <= 6 { flush() }
  inmap { if (indent($0) > 8 && $0 !~ /^ *$/) deeper = 1; next }
  /^      (env|with):$/ { inmap = 1; key = $1; sub(/:$/, "", key); deeper = 0 }
  END { flush() }
' "$ACTION")"
read_maps=0 refused_maps=0 broken=""
while IFS=$'\t' read -r name key kind; do
  [ -n "$name" ] || continue
  read_with step_map "$name" "$key"
  if [ "$kind" = ok ]; then
    if [ "$STATUS" -eq 0 ] && [ -n "$OUT" ] && [ -z "$ERR" ]; then
      read_maps=$((read_maps + 1))
    else
      broken+=" [step_map $name $key: refused or read nothing]"
    fi
  elif [ "$STATUS" -eq 1 ] && [ -z "$OUT" ] && [ -n "$ERR" ]; then
    refused_maps=$((refused_maps + 1))
  else
    broken+=" [step_map $name $key: a map with a deeper line was not refused cleanly]"
  fi
done <<<"$maps"
eq "action.yml: every env: and with: map is read whole, or refused when a value goes deeper" "" "$broken"
pass "action.yml: the file has maps to read" test "$read_maps" -gt 0
pass "action.yml: and a map with a block value, which is refused" test "$refused_maps" -gt 0

# An input of the real file, from its own name line and no further than its own keys. The
# next input is found without the reader: the first key at the inputs' indent below it.
next_input="$(sed -n '/^  version:$/,$p' "$ACTION" | sed 1d | grep -m1 -E '^  [a-z][a-z0-9-]*:$')"
pass "action.yml: there is an input after version to stop before" test -n "$next_input"
read_with input_block version
eq "action.yml: input_block starts at the input's name line" "  version:" "$(head -n1 <<<"$OUT")"
lacks "action.yml: and stops before the next input" "$OUT" "$next_input"

summary
