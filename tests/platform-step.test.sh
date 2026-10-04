#!/usr/bin/env bash
# Tests for the "Determine platform and download URL" and "Fail if binary not
# available" steps of action.yml. Plain bash, no framework:
#   tests/platform-step.test.sh
# Exits non-zero if any case fails.
#
# tests/omni-dev-asset.test.sh pins which asset each (OS, arch) pair gets. This
# pins the wiring around it: that the step asks for the asset the script chose,
# that a pair with no asset never reaches the network, that only a 404 is reported
# as a missing asset, and that every `binary-available=false` carries the `reason`
# the failing step prints. The step scripts are read out of action.yml itself, so
# renaming a step or moving its `run:` block fails here, by name, rather than
# leaving a test of a copy. The step reads everything it needs from environment
# variables its `env:` block fills (nothing is substituted into the script text), so a
# case sets those variables, and the wiring cases at the end check that `env:` fills each.
#
# `curl` is a stub that answers with $FAKE_HTTP_STATUS and logs its arguments, so
# no case touches the network and each can choose the status the lookup sees.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

PLATFORM_BLOCK="$(step_block 'Determine platform and download URL')" || exit 1
PLATFORM="$(step_run 'Determine platform and download URL')" || exit 1
FAIL_BLOCK="$(step_block 'Fail if binary not available')" || exit 1
FAIL="$(step_run 'Fail if binary not available')" || exit 1

BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
printf '%s' "$FAKE_HTTP_STATUS"
# As the real curl does: -w still prints 000, but a transport failure (refused
# connection, DNS, timeout) exits non-zero, and under `bash -e` that ends the step.
[ "$FAKE_HTTP_STATUS" != 000 ] || exit 7
EOF
chmod +x "$BIN/curl"

# output_of <file> <key>: the value a step wrote to $GITHUB_OUTPUT.
output_of() {
  grep "^$2=" "$1" | head -n1 | cut -d= -f2-
}

# run_platform <os> <arch> <http status> [tag]: runs the platform step as the
# runner would, with the variables its `env:` block fills set to the values given.
# Sets STATUS (the step's exit status), OUT (its $GITHUB_OUTPUT file) and CURLS (the
# curl calls it made, one per line).
run_platform() {
  local os=$1 arch=$2 http=$3 tag=${4:-v0.44.0} dir
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  OUT="$dir/output"
  : >"$OUT"
  : >"$dir/curl.log"
  PATH="$BIN:$PATH" GITHUB_OUTPUT="$OUT" CURL_LOG="$dir/curl.log" FAKE_HTTP_STATUS="$http" \
    RELEASE_TAG="$tag" OS="$os" ARCH="$arch" ACTION_PATH="$ROOT" \
    bash --noprofile --norc -eo pipefail -c "$PLATFORM" >"$dir/stdout" 2>&1
  STATUS=$?
  CURLS="$(cat "$dir/curl.log")"
}

# --- a platform with an asset, found ----------------------------------------

run_platform Linux X64 200
eq "Linux X64: the step succeeds" 0 "$STATUS"
eq "Linux X64: the binary is available" true "$(output_of "$OUT" binary-available)"
eq "Linux X64: it takes the x86_64 build" omni-dev-linux.tar.gz "$(output_of "$OUT" binary-name)"
eq "Linux X64: the URL is the release's asset" \
  "https://github.com/rust-works/omni-dev/releases/download/v0.44.0/omni-dev-linux.tar.gz" \
  "$(output_of "$OUT" download-url)"

# The bug: this asked for omni-dev-linux.tar.gz.
run_platform Linux ARM64 200 v0.46.0
eq "Linux ARM64: the binary is available" true "$(output_of "$OUT" binary-available)"
eq "Linux ARM64: it takes the ARM64 build" omni-dev-linux-arm64.tar.gz "$(output_of "$OUT" binary-name)"
has "Linux ARM64: it looks for the ARM64 build" "$CURLS" "/v0.46.0/omni-dev-linux-arm64.tar.gz"
lacks "Linux ARM64: it never asks for the x86_64 build" "$CURLS" "omni-dev-linux.tar.gz"

run_platform macOS ARM64 302
eq "macOS ARM64: a redirect counts as found" true "$(output_of "$OUT" binary-available)"
eq "macOS ARM64: it takes the macOS build" omni-dev-macos-arm64.tar.gz "$(output_of "$OUT" binary-name)"

run_platform Windows X64 200
eq "Windows X64: it takes the Windows build" omni-dev-windows.zip "$(output_of "$OUT" binary-name)"

# --- a platform with no asset: nothing is asked of the network --------------

for pair in "Linux ARM" "Linux X86" "macOS X64"; do
  # shellcheck disable=SC2086 # the pair is two words on purpose
  run_platform $pair 200
  eq "$pair: the step still succeeds, so the failing step can report it" 0 "$STATUS"
  eq "$pair: the binary is not available" false "$(output_of "$OUT" binary-available)"
  has "$pair: the reason names the platform" "$(output_of "$OUT" reason)" "No pre-built omni-dev binary is published for $pair"
  has "$pair: the reason says to build from source" "$(output_of "$OUT" reason)" "use-prebuilt-binary: false"
  eq "$pair: nothing was looked up" "" "$CURLS"
  eq "$pair: no download URL is offered" "" "$(output_of "$OUT" download-url)"
done

# --- a platform with an asset the release lacks -----------------------------

run_platform Linux ARM64 404 v0.44.0
eq "404: the step succeeds" 0 "$STATUS"
eq "404: the binary is not available" false "$(output_of "$OUT" binary-available)"
reason="$(output_of "$OUT" reason)"
has "404: the reason names the release and the asset" "$reason" \
  "omni-dev v0.44.0 has no pre-built omni-dev-linux-arm64.tar.gz for Linux ARM64"
has "404: the reason says to set 'version'" "$reason" "Set 'version' to a release that has it"
has "404: the reason says to build from source" "$reason" "set 'use-prebuilt-binary: false' to build from source"
eq "404: no download URL is offered" "" "$(output_of "$OUT" download-url)"

# Anything but a 404 says the lookup failed, not that the asset is missing.
for http in 000 429 500 503; do
  run_platform Linux ARM64 "$http" v0.45.0
  eq "HTTP $http: the step still succeeds, so the failing step can report it" 0 "$STATUS"
  eq "HTTP $http: the binary is not available" false "$(output_of "$OUT" binary-available)"
  reason="$(output_of "$OUT" reason)"
  has "HTTP $http: the reason says the lookup failed" "$reason" "Could not check whether omni-dev v0.45.0 has a pre-built omni-dev-linux-arm64.tar.gz (HTTP $http"
  lacks "HTTP $http: the reason does not claim the asset is missing" "$reason" "has no pre-built"
  has "HTTP $http: the reason says to re-run" "$reason" "Re-run the job"
done

# --- the failing step prints the reason -------------------------------------

run_fail() { # <reason, or -u to leave it unset>
  if [ "$1" = -u ]; then
    FAIL_OUT="$(env -u REASON bash --noprofile --norc -eo pipefail -c "$FAIL" 2>&1)"
  else
    FAIL_OUT="$(REASON="$1" bash --noprofile --norc -eo pipefail -c "$FAIL" 2>&1)"
  fi
  FAIL_STATUS=$?
}

run_fail "omni-dev v0.44.0 has no pre-built omni-dev-linux-arm64.tar.gz for Linux ARM64."
eq "the failing step exits non-zero" 1 "$FAIL_STATUS"
eq "the failing step prints the reason as the error" \
  "::error::omni-dev v0.44.0 has no pre-built omni-dev-linux-arm64.tar.gz for Linux ARM64." "$FAIL_OUT"

run_fail -u
eq "without a reason it still fails" 1 "$FAIL_STATUS"
has "without a reason it still says what to do" "$FAIL_OUT" "::error::Pre-built binary not available"
has "without a reason it still names the escape hatch" "$FAIL_OUT" "use-prebuilt-binary: false"

# --- the wiring around the scripts -------------------------------------------------------

# The cases above set the variables, so they would pass if `env:` filled them from the
# wrong place. These pin where each comes from. The runner replaces every expression in a
# script before bash sees it, in a comment or a message too, so a script holds none: its
# values arrive in the environment (#39).
# shellcheck disable=SC2016
has "env: RELEASE_TAG is the release the resolve step chose" "$PLATFORM_BLOCK" \
  '        RELEASE_TAG: ${{ steps.resolve-version.outputs.release-tag }}'
# shellcheck disable=SC2016
has "env: OS is the runner's OS" "$PLATFORM_BLOCK" '        OS: ${{ runner.os }}'
# shellcheck disable=SC2016
has "env: ARCH is the runner's architecture" "$PLATFORM_BLOCK" '        ARCH: ${{ runner.arch }}'
# shellcheck disable=SC2016
has "env: ACTION_PATH is where the action's scripts are" "$PLATFORM_BLOCK" \
  '        ACTION_PATH: ${{ github.action_path }}'
# shellcheck disable=SC2016
has "env: the failing step reads the reason the platform step wrote" "$FAIL_BLOCK" \
  '        REASON: ${{ steps.platform.outputs.reason }}'
# shellcheck disable=SC2016
eq "script: the platform step holds no expression" "" "$(grep -n -F '${{' <<<"$PLATFORM" || true)"
# shellcheck disable=SC2016
eq "script: the failing step holds no expression" "" "$(grep -n -F '${{' <<<"$FAIL" || true)"

summary
