#!/usr/bin/env bash
# Fails when a `run:` body of a file the action ships holds a `${{ }}` expression.
#
# Usage: check-run-expressions.sh [file...]
#   With no arguments it scans action.yml, relative to the repository root.
# Exit status: 0 when no `run:` body holds an expression (or only allowlisted ones, and
# every allowlist entry is still needed); 1 when one does, or an allowlist entry matches
# nothing, with an `::error file=..,line=..` annotation per finding and the offending line
# under it; 2 for a file that does not exist or an allowlist entry that is malformed, so a
# wrong path or a typo cannot pass by scanning nothing or allowing nothing.
#
# Why: the runner replaces every `${{ }}` in a `run:` script with its value BEFORE the shell
# parses the script, so a value that holds shell syntax runs as shell (#39). A value reaches
# a script safely through `env:` and is read as "$VAR". The same mechanism has a second face
# (#37): the runner evaluates an expression anywhere in the body, in a comment or a message
# too, and a backslash does not escape one. So nothing in a body is skipped here: a comment
# that holds one is a finding.
#
# What is scanned: the body of every `run:` key, at any indentation and as a `- run:` list
# item or not. That is a block scalar (`run: |`, `>`, `|-`, ...) or a value written after
# `run:`, plus the lines under it indented deeper than the key. Nothing else in the file is
# looked at: `if:`, `with:`, `env:`, `description:` and `default:` are meant to hold
# expressions. It is a line scan, not a YAML parser. A step is the nearest list item at or
# above the `run:` key, named by its `- name:` line or by a `name:` key at the same
# indentation as the item's first key (a step with neither is unnamed). A `run:` key counts
# wherever it is, even as an input under `with:` (a false positive is loud, a miss would not
# be).
#
# The allowlist is for an expression that must stay in a script. It is empty: the inputs
# that are meant to be shell (`setup-commands`, `extra-test-commands`) are evaluated from
# an environment variable instead (see action.yml). An entry is `step name :: expression ::
# reason`, with the separator ` :: ` (a space, two colons, a space) and all three parts
# non-empty. The separator is not `|` because an expression often holds `||`. The step name
# is the step's name without quotes, the expression is what sits between `${{` and `}}`,
# trimmed, and the reason may hold the separator. An entry that matches no finding fails the
# check, so the list only shrinks: remove the entry when the expression goes. Never add one
# for a value a caller supplies that is not meant to be shell.
set -euo pipefail

ALLOWED=(
)

# parse_entry <entry>: sets a_step, a_expr and a_reason; fails when the entry is malformed.
parse_entry() {
  local rest
  a_step="${1%% :: *}"
  [ "$a_step" != "$1" ] || return 1
  rest="${1#* :: }"
  a_expr="${rest%% :: *}"
  [ "$a_expr" != "$rest" ] || return 1
  a_reason="${rest#* :: }"
  [ -n "$a_step" ] && [ -n "$a_expr" ] && [ -n "$a_reason" ]
}

for entry in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  parse_entry "$entry" || {
    echo "::error::check-run-expressions: '${entry}' in ALLOWED is not 'step name :: expression :: reason' (all three non-empty)" >&2
    exit 2
  }
done

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  files=(action.yml)
fi

for file in "${files[@]}"; do
  [ -f "$file" ] || {
    echo "::error::check-run-expressions: no such file: $file" >&2
    exit 2
  }
done

# One record per expression: file, line, step, expression, the line, joined by the
# unit separator (not whitespace, so an empty step name stays an empty field).
findings="$(awk '
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  function nameval(line,    v) {
    v = line
    sub(/^[[:space:]]*(-[[:space:]]+)?name:/, "", v)
    v = trim(v)
    gsub("^[\"" SQ "]|[\"" SQ "]$", "", v)
    return v
  }
  function report(text,    rest, start, end, expr) {
    rest = text
    while ((start = index(rest, "${{")) > 0) {
      rest = substr(rest, start + 3)
      end = index(rest, "}}")
      if (end > 0) { expr = substr(rest, 1, end - 1); rest = substr(rest, end + 2) }
      else { expr = rest; rest = "" }
      printf "%s%s%d%s%s%s%s%s%s\n", FILENAME, SEP, FNR, SEP, step, SEP, trim(expr), SEP, text
    }
  }
  BEGIN { SEP = sprintf("%c", 31); SQ = sprintf("%c", 39) }
  FNR == 1 { inrun = 0; step = ""; stepdash = -1 }
  {
    if (inrun) {
      if ($0 ~ /^[[:space:]]*$/) next
      match($0, /^ */)
      if (RLENGTH > keycol) { report($0); next }
      inrun = 0
    }
    if ($0 ~ /^[[:space:]]*-[[:space:]]/) {
      dash = index($0, "-") - 1
      match($0, /^[[:space:]]*-[[:space:]]+/)
      content = RLENGTH
      if (stepdash < 0 || dash <= stepdash) {
        # A new step, not a list nested inside the last one.
        stepdash = dash; stepcol = content; step = ""
        if ($0 ~ /^[[:space:]]*-[[:space:]]+name:/) step = nameval($0)
      }
    } else if (stepdash >= 0 && $0 ~ /^[[:space:]]*name:/) {
      match($0, /^ */)
      if (RLENGTH == stepcol) step = nameval($0)
    }
    if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?run:([[:space:]]|$)/) {
      match($0, /run:/)
      keycol = RSTART - 1
      report(substr($0, RSTART + 4))
      inrun = 1
    }
  }' "${files[@]}")"

status=0
used=" "
if [ -n "$findings" ]; then
  while IFS=$'\037' read -r file line step expr text; do
    allowed=0
    i=0
    for entry in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
      i=$((i + 1))
      parse_entry "$entry"
      if [ "$a_step" = "$step" ] && [ "$a_expr" = "$expr" ]; then
        allowed=1
        used+="$i "
      fi
    done
    [ "$allowed" -eq 0 ] || continue
    status=1
    where=""
    [ -z "$step" ] || where=" (step '${step}')"
    echo "::error file=${file},line=${line},title=Expression in a run: body::'\${{ ${expr} }}' is replaced by the runner before the shell parses the script${where}; pass it through env: and read it as a variable (see tests/check-run-expressions.sh)"
    echo "  ${file}:${line}: ${text}"
  done <<<"$findings"
fi

i=0
for entry in ${ALLOWED[@]+"${ALLOWED[@]}"}; do
  i=$((i + 1))
  case "$used" in *" $i "*) continue ;; esac
  status=1
  parse_entry "$entry"
  echo "::error::check-run-expressions: ALLOWED entry '${a_step}' for '${a_expr}' matches no expression in: ${files[*]}. Remove it from tests/check-run-expressions.sh (the list only shrinks)"
done

if [ "$status" -eq 0 ]; then
  echo "ok   - no expression in a run: body of: ${files[*]}"
fi
exit "$status"
