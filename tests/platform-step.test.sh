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
# leaving a test of a copy.
#
# `curl` is a stub that answers with $FAKE_HTTP_STATUS and logs its arguments, so
# no case touches the network and each can choose the status the lookup sees.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"
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

# eq <name> <expected> <actual>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$2', got '$3'"; fi
}

# has <name> <text> <fragment>: the text contains the fragment (a fixed string).
has() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "no '$3' in: $2"; fi
}

# lacks <name> <text> <fragment>
lacks() {
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "unexpected '$3' in: $2"; fi
}

# step_run <step name>: the step's `run: |` body, dedented. Both steps keep `run`
# last, so the body ends at the first line indented less than it.
step_run() {
  awk -v name="$1" '
    $0 == "    - name: " name { in_step = 1; next }
    in_step && /^    - name:/ { exit }
    in_step && $0 == "      run: |" { in_run = 1; next }
    in_run && /^        / { print substr($0, 9); next }
    in_run && $0 == "" { print ""; next }
    in_run { exit }
  ' "$ACTION"
}

PLATFORM="$(step_run 'Determine platform and download URL')"
FAIL="$(step_run 'Fail if binary not available')"
if [ -z "$PLATFORM" ] || [ -z "$FAIL" ]; then
  echo "FAIL - could not read the platform and failure steps out of action.yml"
  exit 1
fi

BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
printf '%s' "$FAKE_HTTP_STATUS"
EOF
chmod +x "$BIN/curl"

# output_of <file> <key>: the value a step wrote to $GITHUB_OUTPUT.
output_of() {
  grep "^$2=" "$1" | head -n1 | cut -d= -f2-
}

# The ${{ }} patterns below are literal text to be replaced, not expansions.
# shellcheck disable=SC2016
# run_platform <os> <arch> <http status> [tag]: runs the platform step as the
# runner would, with the expressions it holds replaced by the values given. Sets
# STATUS (the step's exit status), OUT (its $GITHUB_OUTPUT file) and CURLS (the
# curl calls it made, one per line).
run_platform() {
  local os=$1 arch=$2 http=$3 tag=${4:-v0.44.0} script dir
  script="$PLATFORM"
  script="${script//'${{ steps.resolve-version.outputs.release-tag }}'/$tag}"
  script="${script//'${{ runner.os }}'/$os}"
  script="${script//'${{ runner.arch }}'/$arch}"
  script="${script//'${{ github.action_path }}'/$ROOT}"
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  OUT="$dir/output"
  : >"$OUT"
  : >"$dir/curl.log"
  PATH="$BIN:$PATH" GITHUB_OUTPUT="$OUT" CURL_LOG="$dir/curl.log" FAKE_HTTP_STATUS="$http" \
    bash --noprofile --norc -eo pipefail -c "$script" >"$dir/stdout" 2>&1
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

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
