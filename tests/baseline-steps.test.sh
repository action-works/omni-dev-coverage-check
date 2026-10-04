#!/usr/bin/env bash
# Tests for the baseline steps of action.yml: "Find baseline coverage", "Download baseline
# coverage" and the note "Build coverage diff" adds to the comment. Plain bash, no framework:
#   tests/baseline-steps.test.sh
# Exits non-zero if any case fails.
#
# tests/find-baseline.test.sh pins what the lookup script does. This pins the wiring around
# it, which no unit test of the script can see: that the step hands the script every
# variable it requires, from the input it is meant to come from; that the download takes
# the run id the lookup found and decides nothing of its own; that every output a step
# reads is one the script writes; and when the comment says its baseline is an ancestor's.
# The steps are read out of action.yml itself, so renaming one or moving a key fails here,
# by name, rather than leaving a test of a copy.
#
# What this does not reach: `uses: ./` on a runner. pr-paths.yml and e2e-sharded.yml run the
# lookup against the real API, with the README's permissions.

# The `${{ ... }}` expressions below are literal text read out of action.yml, never meant to
# expand, so single-quoting them is the point.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
SCRIPT="$ROOT/scripts/find-baseline.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

# map_value <entries> <key>: one entry of the lines step_map printed. An entry that is not
# there is empty, which is what the "no such key" cases below compare against.
map_value() {
  sed -n "s/^$2: //p" <<<"$1" | head -n1
}

FIND='Find baseline coverage'
DOWNLOAD='Download baseline coverage'
RECOMPUTE='Compute baseline from merge-base (fallback)'
DIFF='Build coverage diff'

# --- "Find baseline coverage" ---------------------------------------------------------------

eq "find: it has the id the later steps read" baseline-lookup "$(step_field "$FIND" id)"
eq "find: it runs on a pull request only" "github.event_name == 'pull_request'" "$(step_field "$FIND" if)"
eq "find: it runs under bash" bash "$(step_field "$FIND" shell)"
eq "find: it runs the script" 'bash "$ACTION_PATH/scripts/find-baseline.sh"' "$(step_field "$FIND" run)"
if [ -x "$SCRIPT" ]; then
  ok "find: the script it runs exists and is executable"
else
  bad "find: the script it runs exists and is executable"
fi

ENV="$(step_map "$FIND" env)" || exit 1
# Where each variable comes from. The input names are the action's own, so a rename of
# one fails here and not as a lookup that quietly uses an empty workflow name.
eq "find: the token is the workflow's" '${{ github.token }}' "$(map_value "$ENV" GH_TOKEN)"
eq "find: the workflow is baseline-workflow" '${{ inputs.baseline-workflow }}' "$(map_value "$ENV" BASELINE_WORKFLOW)"
eq "find: the artifact is baseline-artifact-name" '${{ inputs.baseline-artifact-name }}' "$(map_value "$ENV" BASELINE_ARTIFACT)"
eq "find: it starts from the merge-base" '${{ steps.mb.outputs.sha }}' "$(map_value "$ENV" BASE_REF)"
eq "find: the depth is baseline-ancestor-depth" '${{ inputs.baseline-ancestor-depth }}' "$(map_value "$ENV" ANCESTOR_DEPTH)"
eq "find: the script's directory is the action's" '${{ github.action_path }}' "$(map_value "$ENV" ACTION_PATH)"

# Everything the script insists on is set by the step. (GITHUB_* come from the runner.)
required="$(grep -o '\${[A-Z_]*:?' "$SCRIPT" | sed 's/^\${//; s/:?$//' | grep -v '^GITHUB_' | sort -u | paste -sd' ' -)"
# shellcheck disable=SC2001 # a pattern per line of a block; `${var//}` does not do that
set_by_step="$(sed 's/: .*//' <<<"$ENV" | sort -u | paste -sd' ' -)"
for var in $required; do
  has "find: the script requires $var, and the step sets it" " $set_by_step " " $var "
done
if [ -z "$required" ]; then bad "find: read the variables the script requires"; fi

# Every input the step reads exists.
for input in baseline-workflow baseline-artifact-name baseline-ancestor-depth; do
  if [ "$(awk -v i="  $input:" '$0 == i { print "yes" }' "$ACTION")" = yes ]; then
    ok "find: the input $input is declared"
  else
    bad "find: the input $input is declared"
  fi
done
eq "the depth defaults to 10, which the README and the pr-paths oracle read" "'10'" \
  "$(awk '$0 == "  baseline-ancestor-depth:" { f = 1 } f && /^    default:/ { print $2; exit }' "$ACTION")"

# --- the outputs of the lookup that other steps read -----------------------------------------

written="$(grep -o 'echo "[a-z-]*=' "$SCRIPT" | sed 's/^echo "//; s/=$//' | sort -u | paste -sd' ' -)"
read_by_steps="$(grep -o 'steps\.baseline-lookup\.outputs\.[a-z-]*' "$ACTION" | sed 's/.*outputs\.//' | sort -u | paste -sd' ' -)"
for key in $read_by_steps; do
  has "an action step reads steps.baseline-lookup.outputs.$key, and the script writes it" " $written " " $key "
done
eq "the steps read the run id, the commit and the distance, and whether any was found" \
  "distance found run-id sha" "$read_by_steps"

# --- "Download baseline coverage" -----------------------------------------------------------

eq "download: it keeps the id of the old download step" baseline "$(step_field "$DOWNLOAD" id)"
has "download: it is dawidd6's download" "$(step_field "$DOWNLOAD" uses)" "dawidd6/action-download-artifact@"
IF="$(step_field "$DOWNLOAD" if)"
has "download: it runs on a pull request" "$IF" "github.event_name == 'pull_request'"
has "download: and only when the lookup found a baseline" "$IF" "steps.baseline-lookup.outputs.found == 'true'"
WITH="$(step_map "$DOWNLOAD" with)" || exit 1
eq "download: it takes the run the lookup found" '${{ steps.baseline-lookup.outputs.run-id }}' "$(map_value "$WITH" run_id)"
eq "download: the artifact is baseline-artifact-name" '${{ inputs.baseline-artifact-name }}' "$(map_value "$WITH" name)"
eq "download: into baseline/, where the recompute and the diff look" baseline "$(map_value "$WITH" path)"
eq "download: a miss is a warning" warn "$(map_value "$WITH" if_no_artifact_found)"
# The lookup decides which run, so nothing here may: dawidd6 refuses `commit` beside `run_id`,
# and a `workflow` or `branch` filter would be a second opinion that disagrees with the lookup.
for key in commit workflow branch event pr ref check_artifacts search_artifacts; do
  eq "download: no '$key' filter beside the run id" "" "$(map_value "$WITH" "$key")"
done

# --- "Compute baseline from merge-base (fallback)" says when it built the baseline ----------------

eq "recompute: it has the id the diff step reads" recompute "$(step_field "$RECOMPUTE" id)"
has "recompute: it says when it built the baseline" "$(step_run "$RECOMPUTE")" 'echo "recomputed=true" >> "$GITHUB_OUTPUT"'
recompute_reads="$(grep -o 'steps\.recompute\.outputs\.[a-z-]*' "$ACTION" | sed 's/.*outputs\.//' | sort -u | paste -sd' ' -)"
eq "recompute: the only output any step reads is the one it writes" recomputed "$recompute_reads"

# --- the note "Build coverage diff" adds to the comment -----------------------------------------

DIFF_SCRIPT="$(step_run "$DIFF")" || exit 1
DIFF_ENV="$(step_map "$DIFF" env)" || exit 1
eq "diff: the report is the report input" '${{ inputs.report }}' "$(map_value "$DIFF_ENV" REPORT)"
eq "diff: collapse-ranges" '${{ inputs.collapse-ranges }}' "$(map_value "$DIFF_ENV" COLLAPSE_RANGES)"
eq "diff: all-files" '${{ inputs.all-files }}' "$(map_value "$DIFF_ENV" ALL_FILES)"
eq "diff: strip-prefix" '${{ inputs.strip-prefix }}' "$(map_value "$DIFF_ENV" STRIP_PREFIX)"
eq "diff: report-format" '${{ inputs.report-format }}' "$(map_value "$DIFF_ENV" REPORT_FORMAT)"
eq "diff: ignore-filename-regex" '${{ inputs.ignore-filename-regex }}' "$(map_value "$DIFF_ENV" IGNORE_FILENAME_REGEX)"
eq "diff: the base is the merge-base" '${{ steps.mb.outputs.sha }}' "$(map_value "$DIFF_ENV" BASE_SHA)"
eq "diff: it reads the baseline's commit" '${{ steps.baseline-lookup.outputs.sha }}' "$(map_value "$DIFF_ENV" BASELINE_SHA)"
eq "diff: and its distance" '${{ steps.baseline-lookup.outputs.distance }}' "$(map_value "$DIFF_ENV" BASELINE_DISTANCE)"
eq "diff: and whether the file is the merge-base's own recompute" '${{ steps.recompute.outputs.recomputed }}' "$(map_value "$DIFF_ENV" BASELINE_RECOMPUTED)"

# A stub omni-dev: the two renderings the step asks for, and a log of what it was asked.
BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/omni-dev" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$OMNI_DEV_LOG"
case "$*" in
  *"-o markdown"*) printf '# Coverage\nTotal: **71.4%%**\n' ;;
  *"-o json"*) echo '{"patch_coverage":{"percent":80},"project_delta":{"total_after":71.4}}' ;;
  *) echo "stub omni-dev: unexpected arguments: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$BIN/omni-dev"

# run_diff <distance> <baseline present: yes|no> [recomputed: true]: runs the diff step in an empty directory as the
# runner would, with the variables its env: block fills set to the inputs' defaults. Sets STATUS,
# COMMENT (coverage.md), OUT (its $GITHUB_OUTPUT) and CALLS (what the stub omni-dev was asked).
run_diff() {
  local distance="$1" present="$2" recomputed="${3:-}" script dir
  script="$DIFF_SCRIPT"
  if [[ "$script" == *'${{'* ]]; then
    bad "diff: the step holds no expression" "$(grep -o '\${{[^}]*}}' <<<"$script" | sort -u | paste -sd' ' -)"
    return 1
  fi
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$dir/baseline"
  [ "$present" != yes ] || echo 'TN:x' >"$dir/baseline/coverage-head.lcov"
  : >"$dir/output"
  : >"$dir/calls"
  (
    cd "$dir" && PATH="$BIN:$PATH" GITHUB_OUTPUT="$dir/output" OMNI_DEV_LOG="$dir/calls" \
      ARTIFACT_URL=https://example/artifact RUN_URL=https://example/run BASE_SHA=0000000000000000000000000000000000000001 \
      HEAD_SHA=0000000000000000000000000000000000000002 COMMIT_URL=https://example/commit \
      REPORT=coverage-head.lcov COLLAPSE_RANGES=true ALL_FILES=false STRIP_PREFIX='' REPORT_FORMAT='' \
      IGNORE_FILENAME_REGEX='' \
      BASELINE_SHA=1234567890abcdef1234567890abcdef12345678 BASELINE_DISTANCE="$distance" \
      BASELINE_RECOMPUTED="$recomputed" \
      bash --noprofile --norc -eo pipefail -c "$script" >"$dir/stdout" 2>&1
  )
  STATUS=$?
  COMMENT="$(cat "$dir/coverage.md" 2>/dev/null || true)"
  OUT="$(cat "$dir/output")"
  CALLS="$(cat "$dir/calls")"
}

run_diff 0 yes
eq "diff: the step runs" 0 "$STATUS"
eq "diff: the merge-base's own baseline: the comment is exactly what omni-dev rendered" \
  $'# Coverage\nTotal: **71.4%**' "$COMMENT"
has "diff: the baseline is passed to omni-dev" "$CALLS" "--baseline-report baseline/coverage-head.lcov"
has "diff: the outputs are still written" "$OUT" "comment-path=coverage.md"
has "diff: and the percentages" "$OUT" "patch-percent=80"

run_diff '' yes
eq "diff: no lookup output at all (a miss, or thin mode that skipped it): no note" \
  $'# Coverage\nTotal: **71.4%**' "$COMMENT"

run_diff 1 yes
has "diff: an ancestor's baseline: the note names its commit, linked" "$COMMENT" \
  '[`1234567`](https://example/commit/1234567890abcdef1234567890abcdef12345678)'
has "diff: it says how far back, singular" "$COMMENT" ", 1 commit before the merge-base, which has none."
lacks "diff: not '1 commits'" "$COMMENT" "1 commits"
has "diff: it says the deltas include those commits' changes" "$COMMENT" "The deltas also include whatever those commits changed."
has "diff: the comment omni-dev rendered is still there, before the note" "$COMMENT" $'# Coverage\nTotal: **71.4%**\n\n_Baseline:'
has "diff: the note does not stop the percentages" "$OUT" "line-percent=71.4"

run_diff 3 yes
has "diff: three commits, plural" "$COMMENT" ", 3 commits before the merge-base"

# The lookup said an ancestor's, but the download did not leave a file (it expired between
# the two): the comment compares nothing, so it must not claim a baseline.
run_diff 3 no
eq "diff: no baseline file, so no note, whatever the lookup said" $'# Coverage\nTotal: **71.4%**' "$COMMENT"
lacks "diff: and no baseline is passed to omni-dev" "$CALLS" "--baseline-report"

# The lookup found an ancestor's, but the download left no file under this report's name and the
# recompute built one at the merge-base: the baseline is the merge-base's own, whatever the
# distance says.
run_diff 3 yes true
eq "diff: a recomputed baseline: no note, whatever the lookup's distance" $'# Coverage\nTotal: **71.4%**' "$COMMENT"
has "diff: and it is still passed to omni-dev" "$CALLS" "--baseline-report baseline/coverage-head.lcov"
run_diff 3 yes ''
has "diff's control, not recomputed: the same distance gets its note" "$COMMENT" "3 commits before the merge-base"

summary
