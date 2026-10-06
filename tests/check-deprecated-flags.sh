#!/usr/bin/env bash
# Fails when a file the action ships passes patchcov a flag it has deprecated.
#
# Usage: check-deprecated-flags.sh [file...]
#   With no arguments it scans action.yml and scripts/*.sh, relative to the
#   repository root. Those are the files that can run patchcov for a caller.
# Exit status: 0 when no file holds a listed flag; 1 when one does, with an
# `::error file=..,line=..` annotation per hit and the offending line under it; 2
# for a file that does not exist, so a wrong path cannot pass by scanning nothing.
#
# patchcov keeps a deprecated flag working and prints `warning: --format is
# deprecated; use -o/--output instead` at run time, so nothing else in CI notices
# until a major release removes it and every default (`version: latest`) caller
# breaks. The flag is hidden from `coverage diff --help` by then, so the help
# cannot be checked for it either: the source is.
#
# What counts as a hit:
#   - the flag as a whole word anywhere in the file, not only on the line that
#     runs patchcov. action.yml collects its flags in `args=(...)` / `args+=(...)`
#     and runs `patchcov "${args[@]}"` later, so the flag can sit on either.
#   - `--format` and `--format=json`, not `--report-format` or `--format-x`.
#   - a full-line `#` comment never counts, so a comment can say what replaced a
#     flag. Anything else does, including an echoed message: do not spell a
#     deprecated flag there. The same goes for another command's flag of the same
#     name (`git log --format`): write it another way (`--pretty=format:`).
#
# To add a flag when patchcov deprecates one, add a `flag|use instead` line below.
# The flag must be a long one (`--`, then lowercase letters, digits and dashes): it
# goes into a pattern as it stands, so anything else is refused with exit 2 rather
# than matched wrongly.
set -euo pipefail

# Patchcov inherited the deprecated --format alias; use -o/--output instead.
DEPRECATED=(
  '--format|-o/--output'
)

for entry in "${DEPRECATED[@]}"; do
  [[ "${entry%%|*}" =~ ^--[a-z][a-z0-9-]*$ ]] || {
    echo "::error::check-deprecated-flags: '${entry%%|*}' in DEPRECATED is not a long flag (-- then lowercase letters, digits and dashes)" >&2
    exit 2
  }
done

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
    echo "::error file=${file},line=${line},title=Deprecated patchcov flag::patchcov deprecated '${flag}'; pass ${instead} instead (see tests/check-deprecated-flags.sh)"
    echo "  ${file}:${line}: ${text}"
  done <<<"$hits"
done

if [ "$status" -eq 0 ]; then
  listed=""
  for entry in "${DEPRECATED[@]}"; do listed+="${listed:+, }${entry%%|*}"; done
  echo "ok   - none of ${listed} in: ${files[*]}"
fi
exit "$status"
