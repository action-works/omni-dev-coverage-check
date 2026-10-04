#!/usr/bin/env bash
# Fails when a file the action ships passes omni-dev a flag it has deprecated.
#
# Usage: check-deprecated-flags.sh [file...]
#   With no arguments it scans action.yml and scripts/*.sh, relative to the
#   repository root. Those are the files that can run omni-dev for a caller.
# Exit status: 0 when no file holds a listed flag; 1 when one does, with an
# `::error file=..,line=..` annotation per hit and the offending line under it; 2
# for a file that does not exist, so a wrong path cannot pass by scanning nothing.
#
# omni-dev keeps a deprecated flag working and prints `warning: --format is
# deprecated; use -o/--output instead` at run time, so nothing else in CI notices
# until a major release removes it and every default (`version: latest`) caller
# breaks. The flag is hidden from `coverage diff --help` by then, so the help
# cannot be checked for it either: the source is.
#
# What counts as a hit:
#   - the flag as a whole word anywhere in the file, not only on the line that
#     runs omni-dev. action.yml collects its flags in `args=(...)` / `args+=(...)`
#     and runs `omni-dev "${args[@]}"` later, so the flag can sit on either.
#   - `--format` and `--format=json`, not `--report-format` or `--format-x`.
#   - a full-line `#` comment never counts, so a comment can say what replaced a
#     flag. Anything else does, including an echoed message: do not spell a
#     deprecated flag there. The same goes for another command's flag of the same
#     name (`git log --format`): write it another way (`--pretty=format:`).
#
# To add a flag when omni-dev deprecates one, add a `flag|use instead` line below.
set -euo pipefail

# omni-dev 0.32.0 added -o/--output and deprecated --format (rust-works/omni-dev#1125).
DEPRECATED=(
  '--format|-o/--output'
)

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  files=(action.yml scripts/*.sh)
fi

for file in "${files[@]}"; do
  [ -f "$file" ] || {
    echo "::error::check-deprecated-flags: no such file: $file" >&2
    exit 2
  }
done

status=0
for entry in "${DEPRECATED[@]}"; do
  flag="${entry%%|*}"
  instead="${entry#*|}"
  hits="$(awk -v flag="$flag" '
    BEGIN { re = "(^|[^[:alnum:]_-])" flag "([^[:alnum:]_-]|$)" }
    /^[[:space:]]*#/ { next }
    $0 ~ re { printf "%s\t%d\t%s\n", FILENAME, FNR, $0 }' "${files[@]}")"
  [ -n "$hits" ] || continue
  status=1
  while IFS=$'\t' read -r file line text; do
    echo "::error file=${file},line=${line},title=Deprecated omni-dev flag::omni-dev deprecated '${flag}'; pass ${instead} instead (see tests/check-deprecated-flags.sh)"
    echo "  ${file}:${line}: ${text}"
  done <<<"$hits"
done

if [ "$status" -eq 0 ]; then
  listed=""
  for entry in "${DEPRECATED[@]}"; do listed+="${listed:+, }${entry%%|*}"; done
  echo "ok   - none of ${listed} in: ${files[*]}"
fi
exit "$status"
