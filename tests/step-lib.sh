#!/usr/bin/env bash
# Readers for the text of action.yml, for the tests that run a step's script or match on
# a step or an input. Source it and set ACTION to the file to read:
#
#   ACTION="$ROOT/action.yml"
#   # shellcheck source-path=SCRIPTDIR
#   # shellcheck source=step-lib.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"
#   SCRIPT="$(step_run 'Check omni-dev supports the flags this run uses')" || exit 1
#
#   step_run <step name>    the step's `run:` script, dedented
#   step_block <step name>  the whole step, from its `- name:` line, as written
#   input_block <name>      the input's block under `inputs:`, as written
#
# They read the text, not the YAML, so they depend on the layout action.yml has: a step is
# `    - name: <name>` (4 spaces), its keys sit at 6 spaces, and `run: |` is followed by a
# body at 8. That layout is written down here and nowhere else: this is the one copy, so a
# change to it is one edit.
#
# What they do outside that layout is refuse: print nothing on stdout, say why on stderr
# and return 1, so `|| exit 1` stops a test that read nothing, or read the wrong thing.
# (Three copies of this once returned an empty block for `run: |-` and, for a step with no
# `run:` ahead of an unnamed step, that step's script. Only an empty block was caught.)
# A refusal is for:
#   - $ACTION unset or unreadable; a step that is not found, or is found more than once
#     (steps at another indent, or with `name:` after another key, are "not found");
#   - step_run: a step with no `run:`; a `run:` that is not a literal block (`|`, `|-` or
#     `|+`, which give the same script once `$(...)` strips the trailing newlines): an inline
#     command, a folded `>`, an indentation indicator `|2`, a trailing comment; a body not
#     indented 8 spaces; an empty body;
#   - input_block: a name that is not under `inputs:` (an output of that name is not it).
#
# A step ends at the next line indented 4 spaces or less (the next step, named or not, or
# a key after the list), so another step's `run:` is never read as this one's. The same
# line ends an input's block at 2 spaces. That reads a comment at those indents as the end,
# so a comment there in the middle of a step would cut it short: action.yml has none.
# A body ends at the first non-blank line indented less than it, and a whitespace-only line
# inside it is an empty line.
#
# The awk is POSIX (no regex intervals, no gensub): the ubuntu runners' default awk is mawk.
# tests/step-lib.test.sh tests this file.

# _action_ok <caller>: $ACTION names a readable file.
_action_ok() {
  if [ -z "${ACTION:-}" ] || [ ! -r "$ACTION" ]; then
    echo "$1: ACTION must name the file to read, and '${ACTION:-}' is not a readable one" >&2
    return 1
  fi
}

# _step_once <caller> <step name>: the file holds exactly one step of that name.
_step_once() {
  local count
  _action_ok "$1" || return 1
  count="$(grep -cxF -- "    - name: $2" "$ACTION")" || true
  if [ "${count:-0}" -eq 0 ]; then
    echo "$1: no step named \"$2\" in $ACTION (a step is read as '    - name: <name>', 4 spaces of indent)" >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "$1: $count steps named \"$2\" in $ACTION, so which one is meant?" >&2
    return 1
  fi
}

# step_block <step name>: the whole step, from its `- name:` line to the line before the next.
step_block() {
  _step_once step_block "$1" || return 1
  STEP_NAME="$1" awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    BEGIN { head = "    - name: " ENVIRON["STEP_NAME"] }
    $0 == head { in_step = 1; print; next }
    in_step && $0 !~ /^ *$/ && indent($0) <= 4 { exit }
    in_step { print }
  ' "$ACTION"
}

# step_run <step name>: the step's `run:` script, dedented.
step_run() {
  _step_once step_run "$1" || return 1
  STEP_NAME="$1" STEP_FILE="$ACTION" awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function refuse(why) {
      printf "step_run: step \"%s\" in %s: %s\n", ENVIRON["STEP_NAME"], ENVIRON["STEP_FILE"], why > "/dev/stderr"
      failed = 1
      exit 1
    }
    BEGIN { head = "    - name: " ENVIRON["STEP_NAME"] }
    { ind = indent($0); blank = ($0 ~ /^ *$/) }

    # state 3, the body: it ends at the first non-blank line indented less than 8.
    state == 3 {
      if (blank) { body[++n] = (length($0) > 8 ? substr($0, 9) : ""); next }
      if (ind >= 8) { body[++n] = substr($0, 9); next }
      exit
    }

    # state 2, after `run: |` and before the first line of the body.
    state == 2 {
      if (blank) { body[++n] = (length($0) > 8 ? substr($0, 9) : ""); next }
      if (ind <= 6) refuse("the run: block is empty")
      if (ind != 8) refuse("the run: body is indented " ind " spaces, and this reads one indented 8")
      state = 3
      content = 1
      body[++n] = substr($0, 9)
      next
    }

    # state 1, in the step and looking for its `run:` at the indent of its keys.
    state == 1 {
      if (!blank && ind <= 4) refuse("the step has no run: (the next step, or the end of the list, comes first)")
      if (ind == 6 && index($0, "      run:") == 1) {
        if ($0 !~ /^      run: [|][-+]? *$/) refuse("run: is not a literal block (| or |- or |+): " $0)
        state = 2
      }
      next
    }

    state == 0 && $0 == head { state = 1; next }

    END {
      if (failed) exit 1
      if (state < 2) refuse("the step has no run:")
      if (!content) refuse("the run: block is empty")
      for (i = 1; i <= n; i++) print body[i]
    }
  ' "$ACTION"
}

# input_block <name>: the input's block under `inputs:`, up to the next key.
input_block() {
  _action_ok input_block || return 1
  INPUT_NAME="$1" INPUT_FILE="$ACTION" awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    BEGIN { head = "  " ENVIRON["INPUT_NAME"] ":" }
    # A key at column 0 starts or ends a section; only `inputs:` is read.
    /^[^ #]/ {
      if (in_input) exit
      in_inputs = ($0 == "inputs:")
      next
    }
    in_inputs && !in_input && $0 == head { in_input = 1; found = 1; print; next }
    in_input {
      if ($0 !~ /^ *$/ && indent($0) <= 2) exit
      print
    }
    END {
      if (!found) {
        printf "input_block: no input named \"%s\" under inputs: in %s\n", ENVIRON["INPUT_NAME"], ENVIRON["INPUT_FILE"] > "/dev/stderr"
        exit 1
      }
    }
  ' "$ACTION"
}
