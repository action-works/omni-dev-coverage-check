#!/usr/bin/env bash
# Prints the deprecation warnings that one job of the current workflow run logged.
#
# Usage: job-deprecations.sh <job name>
# Environment, retries and exit status: as job-log.sh, which reads the log.
#
# omni-dev keeps a deprecated flag working and prints, each time it is used,
#   warning: --format is deprecated; use -o/--output instead
# on stderr. Nothing else in CI notices that, so a flag the action passes can stay
# deprecated until a major release removes it and every caller on `version: latest`
# breaks. check-deprecated-flags.sh finds the flags it has been told about; this
# finds any flag omni-dev has deprecated, as long as a step ran it.
#
# Output: one line per log line that begins, after the runner's timestamp, with
# `warning:` and holds "deprecated" in any case, the timestamp removed. Empty if the
# job logged none. What that rule includes and leaves out, from real logs:
#   - It is a line a program printed. The runner's echo of a step's script starts
#     with a colour code, so a script that holds the same words (an `echo` of the
#     message, a comment) does not count. None does today; the rule does not depend
#     on that, as job-errors.sh does not depend on it for `##[error]`.
#   - It is not the runner's own `##[warning]Node.js 20 is deprecated...`, nor
#     node's `(node:N) [DEP0040] DeprecationWarning: ...`. Both concern the
#     actions' runtime, not a flag this action passes, and both appear in every log.
#   - It does include another tool's `warning: ... deprecated`, such as cargo's or
#     rustc's, because omni-dev's wording for a deprecation that is not a flag is
#     not known. A hit says which line to look at.
#
# An empty result says something only about the call sites the job ran. The comment
# and percentages diffs and the patch gate run on a pull request alone; the thin-mode
# line gate runs on any event. So the caller has to know which steps the job reached
# (on a pull request, all of them), or an empty result proves nothing.
set -euo pipefail

name="${1:?usage: job-deprecations.sh <job name>}"
log="$(bash "$(dirname "${BASH_SOURCE[0]}")/job-log.sh" "$name")"

printf '%s\n' "$log" | sed -n -E 's/^[^ ]*[0-9]Z (warning: .*[Dd]eprecated.*)$/\1/p'
