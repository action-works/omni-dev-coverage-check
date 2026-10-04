#!/usr/bin/env bash
# Tests for tests/install-cache.sh. Plain bash, no framework:
#   tests/install-cache.test.sh
# Exits non-zero if any case fails.
#
# The script decides which events install the omni-dev binary for real (the cache
# prefix) and what a job that restored it from the cache must do (the check), so the
# cases that matter most are the ones where a wrong answer is silent: a prefix that does
# not change when the install code or the run does (the cache hits and nothing says so),
# an empty hash (a constant prefix), and a cache hit on a run that cannot have saved one.
#
# The script runs under `env -i`: on a runner the tests themselves run with
# GITHUB_EVENT_NAME and GITHUB_RUN_ID set, and a case must set what it is about.
#
# The last cases read action.yml and integration.yml themselves, because a script that
# is right does nothing if the workflow does not use it, and the hash is only as good
# as the files it covers: the action exposes the output the check reads, the install
# steps run nothing the hash does not cover, and every scenario of `thin-mode` takes
# the prefix. A rename, a new scenario or a new install script fails here, by name.

# The `${{ ... }}` expressions and shell lines matched below are literal text read out of
# the workflow, never meant to expand, so single-quoting them is the point.
# shellcheck disable=SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tests/install-cache.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

ACTION="$ROOT/action.yml"
WORKFLOW="$ROOT/.github/workflows/integration.yml"

# hashFiles gives 64 hex characters. A and B differ in their first 16.
HASH_A=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
HASH_B=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210

# run <event> <run id> <attempt> <hash> <script arguments...>
# Sets STATUS, OUT (stdout) and ERR (stderr) of the script. The leg of a matrix comes
# from $LEG, set on the call (`LEG=latest run ...`), and is empty otherwise.
run() {
  local event=$1 id=$2 attempt=$3 hash=$4
  shift 4
  OUT="$(env -i PATH="$PATH" GITHUB_EVENT_NAME="$event" GITHUB_RUN_ID="$id" \
    GITHUB_RUN_ATTEMPT="$attempt" INSTALL_CODE_HASH="$hash" INSTALL_CACHE_LEG="${LEG-}" \
    bash "$SCRIPT" "$@" 2>"$WORK/err")"
  STATUS=$?
  ERR="$(<"$WORK/err")"
}

# prefix_of <event> <run id> <attempt> <hash>: the prefix the script printed, or, if it
# failed, "FAILED(<status>)", which no case expects. An empty string would be different
# from any prefix, so a `!=` against it would pass for a script that printed nothing; the
# cases below compare with the exact prefix instead.
prefix_of() {
  run "$1" "$2" "$3" "$4" prefix
  if [ "$STATUS" -eq 0 ]; then printf '%s' "$OUT"; else printf 'FAILED(%s)' "$STATUS"; fi
}

# --- prefix: the events that install on a change to the install code -----------------

for event in pull_request push; do
  run "$event" 100 1 "$HASH_A" prefix
  eq "$event: the prefix is the first 16 characters of the hash of the install code" "install-0123456789abcdef-" "$OUT"
  eq "$event: it exits 0" 0 "$STATUS"
  eq "$event: it says nothing else on stderr" "" "$ERR"
done

# A change to the install code changes the hash, and so the key, so the cache misses.
changed="$(prefix_of pull_request 100 1 "$HASH_B")"
unchanged="$(prefix_of pull_request 100 1 "$HASH_A")"
pass "pull_request: a different hash gives a different prefix" test "$changed" != "$unchanged"
eq "pull_request: ... which is the next hash's 16 characters" "install-fedcba9876543210-" "$changed"

# Runs on unchanged code reuse the entry: the run does not change the prefix, or each
# push to a pull request would write an entry nothing restores.
eq "pull_request: another run of the same code gets the same prefix" "$unchanged" "$(prefix_of pull_request 999 3 "$HASH_A")"
eq "push: the same code gives the pull request's prefix" "$unchanged" "$(prefix_of push 100 1 "$HASH_A")"

# --- prefix: the events that install every time --------------------------------------

for event in schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" prefix
  eq "$event: the prefix is made of the run and the attempt" "run-100-1-" "$OUT"
  eq "$event: it exits 0" 0 "$STATUS"
  eq "$event: it says nothing else on stderr" "" "$ERR"
done

base="$(prefix_of schedule 100 1 "$HASH_A")"
eq "schedule: another run gets another prefix" "run-101-1-" "$(prefix_of schedule 101 1 "$HASH_A")"
eq "schedule: a re-run (another attempt) gets another prefix" "run-100-2-" "$(prefix_of schedule 100 2 "$HASH_A")"
eq "schedule: the install code does not matter, only the run does" "$base" "$(prefix_of schedule 100 1 "$HASH_B")"
eq "schedule: no hash is needed" "$base" "$(prefix_of schedule 100 1 "")"
pass "the two kinds of prefix cannot be the same key" test "$base" != "$unchanged"

# The legs of one job can resolve to the same key (a pinned 0.46.0 and latest, when latest
# is 0.46.0), so each leg needs its own prefix, on every event. Shared, whichever leg
# finishes first saves the entry the other restores, and the other never runs the install
# (it happened on this change's own pull request); on a run-id event `check` would also
# fail a leg that did nothing wrong.
eq "schedule: a leg is part of the prefix" "run-100-1-latest-" "$(LEG=latest prefix_of schedule 100 1 "$HASH_A")"
eq "workflow_dispatch: ... and so is a pinned leg's" "run-100-1-0.46.0-" "$(LEG=0.46.0 prefix_of workflow_dispatch 100 1 "$HASH_A")"
pass "schedule: two legs of one run cannot share a prefix" test "$(LEG=latest prefix_of schedule 100 1 "$HASH_A")" != "$(LEG=0.46.0 prefix_of schedule 100 1 "$HASH_A")"
eq "pull_request: a leg is part of the hash prefix" "install-0123456789abcdef-latest-" "$(LEG=latest prefix_of pull_request 100 1 "$HASH_A")"
eq "push: ... and so is a pinned leg's" "install-0123456789abcdef-0.46.0-" "$(LEG=0.46.0 prefix_of push 100 1 "$HASH_A")"
pass "pull_request: two legs of one run cannot share a prefix" test "$(LEG=latest prefix_of pull_request 100 1 "$HASH_A")" != "$(LEG=0.46.0 prefix_of pull_request 100 1 "$HASH_A")"
eq "pull_request: a leg does not change which code the prefix follows" "install-fedcba9876543210-latest-" "$(LEG=latest prefix_of pull_request 100 1 "$HASH_B")"

LEG="a b" run schedule 100 1 "$HASH_A" prefix
eq "schedule with a leg that is not safe in a key: exits 1" 1 "$STATUS"
LEG="a b" run pull_request 100 1 "$HASH_A" prefix
eq "pull_request with a leg that is not safe in a key: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
eq "  and prints no prefix" "" "$OUT"
has "  and says which variable is wrong" "$ERR" "INSTALL_CACHE_LEG"
LEG='x/../y' run schedule 100 1 "$HASH_A" prefix
eq "schedule with a leg that holds a slash: exits 1" 1 "$STATUS"

# --- prefix: what it refuses ---------------------------------------------------------

# An empty hash is what hashFiles gives when its globs match nothing. A prefix that
# ignored it would be the same on every run and the cache would never miss.
run pull_request 100 1 "" prefix
eq "pull_request with no hash: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says which variable is wrong" "$ERR" "::error::install-cache.sh: INSTALL_CODE_HASH"
has "  and says what the globs may have matched" "$ERR" "do the globs match nothing?"

run push 100 1 "not-a-hash" prefix
eq "push with a hash that is not hex: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run push 100 1 "abc123" prefix
eq "push with a hash under 16 characters: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run schedule "" 1 "$HASH_A" prefix
eq "schedule with no run id: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says what it needs" "$ERR" "GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT"

run workflow_dispatch 100 "" "$HASH_A" prefix
eq "workflow_dispatch with no attempt: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run schedule "12 34" 1 "$HASH_A" prefix
eq "schedule with a run id that is not a number: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"

run "" 100 1 "$HASH_A" prefix
eq "no event: exits 1" 1 "$STATUS"
eq "  and prints no prefix" "" "$OUT"
has "  and says the event is unknown" "$ERR" "GITHUB_EVENT_NAME is not set"

# --- check: the install ran ----------------------------------------------------------

for event in pull_request push schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" check false
  eq "$event, no cache hit: exits 0" 0 "$STATUS"
  has "  and says the install ran" "$OUT" "omni-dev was installed in this job"
  eq "  and says nothing on stderr" "" "$ERR"
done

# --- check: a cache hit --------------------------------------------------------------

# On unchanged install code the entry is the one an earlier run saved: correct, and the
# log says the download and the extraction did not run here.
for event in pull_request push; do
  run "$event" 100 1 "$HASH_A" check true
  eq "$event, cache hit: exits 0" 0 "$STATUS"
  has "  and says it came from the cache" "$OUT" "omni-dev came from the cache, not from an install"
  has "  and says the install did not run" "$OUT" "did not run in this job"
  lacks "  and does not say it was installed" "$OUT" "omni-dev was installed in this job"
done

# Their prefix is unique to the run, so there was nothing to restore: the prefix did not
# reach the action, which is exactly what the check is there to catch.
for event in schedule workflow_dispatch; do
  run "$event" 100 1 "$HASH_A" check true
  eq "$event, cache hit: exits 1" 1 "$STATUS"
  has "  and names the event" "$ERR" "on a $event run"
  has "  and says the prefix did not reach the action" "$ERR" "the prefix did not reach the action"
  has "  and is an error annotation" "$ERR" "::error::install-cache.sh:"
  eq "  and prints nothing on stdout" "" "$OUT"
done

run "" 100 1 "$HASH_A" check true
eq "cache hit with no event: exits 1" 1 "$STATUS"
has "  and says the event is unknown" "$ERR" "GITHUB_EVENT_NAME is not set"

# --- check: no usable answer ---------------------------------------------------------

# A scenario that failed exposes no outputs, so the value arrives empty. Treating that as
# a hit or as an install would pass whatever the action did.
run pull_request 100 1 "$HASH_A" check ""
eq "no value: exits 2, as a usage error" 2 "$STATUS"
has "  and says what it needed" "$ERR" "omni-dev-cache-hit output"
eq "  and prints nothing on stdout" "" "$OUT"

run pull_request 100 1 "$HASH_A" check
eq "no argument: exits 2" 2 "$STATUS"

run pull_request 100 1 "$HASH_A" check maybe
eq "a value that is neither: exits 1" 1 "$STATUS"
has "  and names it" "$ERR" "'maybe'"

run pull_request 100 1 "$HASH_A" check True
eq "True is not true: exits 1" 1 "$STATUS"

# --- usage ---------------------------------------------------------------------------

run pull_request 100 1 "$HASH_A"
eq "no subcommand: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" restore
eq "an unknown subcommand: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" prefix extra
eq "prefix with an argument: exits 2" 2 "$STATUS"
run pull_request 100 1 "$HASH_A" check true false
eq "check with two arguments: exits 2" 2 "$STATUS"

# --- wiring: the action exposes what the check reads --------------------------------

CACHE_STEP="$(step_block 'Cache omni-dev binary')" || exit 1
has "action.yml: the cache step has the id the output reads" "$CACHE_STEP" "id: cache-omni-dev"
# The whole mechanism: a prefix that never reaches the key changes nothing, and on a pull
# request and a push `check` accepts a hit, so nothing else would notice.
has "action.yml: the cache key starts with the cache-prefix input" "$CACHE_STEP" \
  "key: \${{ inputs.cache-prefix }}omni-dev-"

OUTPUT_BLOCK="$(awk '
  /^outputs:/ { in_outputs = 1; next }
  in_outputs && /^  omni-dev-cache-hit:/ { printing = 1; print; next }
  printing && /^  [A-Za-z]/ { exit }
  printing { print }
' "$ACTION")"
has "action.yml: it exposes omni-dev-cache-hit" "$OUTPUT_BLOCK" "omni-dev-cache-hit:"
# `actions/cache` can leave its own output empty on a miss; the comparison reads that as false.
has "action.yml: ... as the cache step's hit, true only for 'true'" "$OUTPUT_BLOCK" \
  "value: \${{ steps.cache-omni-dev.outputs.cache-hit == 'true' }}"

# --- wiring: the hash covers the install code ----------------------------------------

THIN="$(awk '
  /^  thin-mode:$/ { in_job = 1; next }
  in_job && /^  [A-Za-z0-9_-]+:$/ { exit }
  in_job { print }
' "$WORKFLOW")"
pass "integration.yml: found the thin-mode job" test -n "$THIN"

HASH_EXPR="$(grep -o "hashFiles([^)]*)" <<<"$THIN" | sort -u)"
eq "thin-mode hashes action.yml and scripts/*.sh, and nothing else" \
  "hashFiles('action.yml', 'scripts/*.sh')" "$HASH_EXPR"

# The install is the steps from the version to the printed version. Whatever they run
# from the action's directory has to be a file the hash covers, or a change to it is
# cached over again. (A script written by hand into the list is the maintenance this
# check replaces.)
# The two ends are read through step-lib, which refuses a step that is missing or doubled,
# so renaming one fails here by name. The span between them takes in a step added later.
step_block 'Resolve omni-dev version' >/dev/null || exit 1
step_block 'Print omni-dev version' >/dev/null || exit 1
INSTALL_STEPS="$(awk '
  /^    - name: Resolve omni-dev version$/ { printing = 1 }
  /^    - name: Print omni-dev version$/ { printing = 0 }
  printing { print }
' "$ACTION")"
pass "action.yml: found the install steps" test -n "$INSTALL_STEPS"
for name in 'Cache omni-dev binary' 'Determine platform and download URL' 'Download pre-built binary'; do
  has "the install steps run from the version to the printed version, and take in '$name'" \
    "$INSTALL_STEPS" "    - name: $name"
done

# $ACTION_PATH/x and ${ACTION_PATH}/x both name a file in the action's directory.
RUN_FROM_ACTION="$(grep -oE '[$]\{?ACTION_PATH\}?/[^" ]*' <<<"$INSTALL_STEPS" | sed -E 's/^[$]\{?ACTION_PATH\}?\///' | sort -u)"
has "the install steps run the asset script from the action's directory" "$RUN_FROM_ACTION" "scripts/omni-dev-asset.sh"
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$file" in
    # `*` in a case pattern crosses a slash, where the glob in hashFiles does not.
    scripts/*/*) bad "the install runs $file, which hashFiles('scripts/*.sh') does not reach (it does not descend)" \
      "move it to scripts/, or widen the globs in thin-mode and HASH_EXPR here" ;;
    scripts/*.sh) ok "the install runs $file, which scripts/*.sh covers" ;;
    *) bad "the install runs $file, which the hash of action.yml and scripts/*.sh does not cover" \
      "move it under scripts/, or widen the globs in thin-mode and HASH_EXPR here" ;;
  esac
done <<<"$RUN_FROM_ACTION"

# --- wiring: every scenario of thin-mode takes the prefix and the job checks -----------

SCENARIOS="$(grep -c '^        uses: \./$' <<<"$THIN")"
PREFIXED="$(grep -c '^          cache-prefix: \${{ steps.install-cache.outputs.prefix }}$' <<<"$THIN")"
pass "thin-mode runs the action at least once" test "$SCENARIOS" -ge 1
eq "every scenario of thin-mode passes the prefix ($SCENARIOS of them)" "$SCENARIOS" "$PREFIXED"

# The prefix is a step output: read before it is written, it is empty, and an empty
# prefix is the default key, which hits.
PREFIX_AT="$(grep -n '^        id: install-cache$' <<<"$THIN" | head -n1 | cut -d: -f1)"
FIRST_USE_AT="$(grep -n '^        uses: \./$' <<<"$THIN" | head -n1 | cut -d: -f1)"
pass "the prefix step is in thin-mode" test -n "$PREFIX_AT"
pass "the prefix step runs before the first scenario" test "${PREFIX_AT:-999999}" -lt "${FIRST_USE_AT:-0}"

has "the prefix step takes the hash through env" "$THIN" \
  "INSTALL_CODE_HASH: \${{ hashFiles('action.yml', 'scripts/*.sh') }}"
has "the prefix step names the leg, so the legs of a run cannot share a prefix" "$THIN" \
  "INSTALL_CACHE_LEG: \${{ matrix.omni-dev }}"
has "the prefix is taken as an assignment, so a failure ends the step" "$THIN" \
  'prefix="$(bash tests/install-cache.sh prefix)"'
has "the checking step reads the output of the first scenario" "$THIN" \
  "CACHE_HIT: \${{ steps.s1.outputs.omni-dev-cache-hit }}"
has "the checking step calls check, and a failure is counted" "$THIN" \
  'bash tests/install-cache.sh check "$CACHE_HIT" || status=1'

summary
