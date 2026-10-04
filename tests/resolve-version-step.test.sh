#!/usr/bin/env bash
# Tests for the "Resolve omni-dev version" step of action.yml. Plain bash, no
# framework:
#   tests/resolve-version-step.test.sh
# Exits non-zero if any case fails.
#
# The step resolves `version: latest` with one GitHub API call. Run unauthenticated
# from a shared runner IP that call hit the 60/hr limit and failed the whole job (#1),
# so it now sends the token and tries three times. This pins that: the header, the
# retries and their delays, the message after the last attempt, and that a pinned
# version never touches the network. The step's script is read out of action.yml
# itself, so renaming the step or moving its `run:` fails here, by name, rather than
# leaving a test of a copy.
#
# `curl` is a stub that replays the responses a case scripts, one per call, and logs
# each call's arguments; `sleep` is a stub that logs its argument and returns, so no
# case touches the network or waits. `jq` is the real one, as on the runner.

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

if ! command -v jq >/dev/null; then
  echo "FAIL - jq is not installed; the step needs it, as does this test"
  exit 1
fi

# step_block <step name>: the whole step, from its `- name:` line to the next step's.
step_block() {
  awk -v name="$1" '
    $0 == "    - name: " name { in_step = 1; print; next }
    in_step && /^    - name:/ { exit }
    in_step { print }
  ' "$ACTION"
}

# step_run <step name>: the step's `run: |` body, dedented. The body ends at the
# first line indented less than it.
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

# input_block <input name>: the input's block under `inputs:`, up to the next key.
input_block() {
  awk -v name="$1" '
    $0 == "  " name ":" { in_input = 1; print; next }
    in_input && /^  [^ ]/ { exit }
    in_input && /^[^ ]/ { exit }
    in_input { print }
  ' "$ACTION"
}

STEP_NAME='Resolve omni-dev version'
BLOCK="$(step_block "$STEP_NAME")"
RESOLVE="$(step_run "$STEP_NAME")"
if [ -z "$BLOCK" ] || [ -z "$RESOLVE" ]; then
  echo "FAIL - could not read the '$STEP_NAME' step out of action.yml"
  exit 1
fi

BIN="$WORK/bin"
mkdir "$BIN"
# One argument per line under a `call` header, so a case can look for an exact
# argument (or the absence of one) instead of a substring of a joined line. The
# Nth call replays $CASE_DIR/response.N; a leading `!<code>` in it means curl
# failed with that status and printed nothing, as for a refused connection. A call
# past the scripted ones gets an empty body, which the call count then exposes.
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
n=$(( $(grep -c '^call ' "$CASE_DIR/curl.log") + 1 ))
{ echo "call $n"; printf '%s\n' "$@"; } >>"$CASE_DIR/curl.log"
[ -f "$CASE_DIR/response.$n" ] || exit 0
response="$(cat "$CASE_DIR/response.$n")"
if [[ "$response" == '!'* ]]; then
  echo "curl: (7) Failed to connect to api.github.com port 443" >&2
  exit "${response#!}"
fi
printf '%s' "$response"
EOF
cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CASE_DIR/sleep.log"
EOF
chmod +x "$BIN/curl" "$BIN/sleep"

TOKEN='ghs_SENTINEL_not_a_real_token'
RATE_LIMITED='{"message":"API rate limit exceeded for 10.0.0.1. (But here'"'"'s the good news: Authenticated requests get a higher rate limit.)","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}'

# The ${{ }} patterns below are literal text to be replaced, not expansions.
# shellcheck disable=SC2016
# run_resolve <version> <token> [response...]: runs the step as the runner would,
# with the one expression its script holds replaced by <version>, `GH_TOKEN` set to
# <token> as the step's `env:` does, and the responses replayed one per curl call.
# Sets STATUS (the step's exit status), OUT (the contents of its $GITHUB_OUTPUT),
# LOG (what it printed), CALLS (curl calls made), CURLS (their arguments) and SLEEPS
# (the sleeps asked for, space-separated).
run_resolve() {
  local version=$1 token=$2 script dir i=0
  shift 2
  script="${RESOLVE//'${{ inputs.version }}'/$version}"
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  : >"$dir/output"
  : >"$dir/curl.log"
  : >"$dir/sleep.log"
  for response in "$@"; do
    i=$((i + 1))
    printf '%s' "$response" >"$dir/response.$i"
  done
  PATH="$BIN:$PATH" CASE_DIR="$dir" GITHUB_OUTPUT="$dir/output" GH_TOKEN="$token" \
    bash --noprofile --norc -eo pipefail -c "$script" >"$dir/log" 2>&1
  STATUS=$?
  OUT="$(cat "$dir/output")"
  LOG="$(cat "$dir/log")"
  CALLS="$(grep -c '^call ' "$dir/curl.log" || true)"
  CURLS="$(cat "$dir/curl.log")"
  SLEEPS="$(tr '\n' ' ' <"$dir/sleep.log")"
  SLEEPS="${SLEEPS% }"
}

# arg_present <name> <arg>: some curl call received exactly that argument.
arg_present() {
  if grep -qxF -- "$2" <<<"$CURLS"; then ok "$1"; else bad "$1" "no argument '$2' in: $CURLS"; fi
}

# --- a pinned version never asks GitHub --------------------------------------

run_resolve 0.45.0 "$TOKEN" '{"tag_name":"v9.9.9"}'
eq "pinned: the step succeeds" 0 "$STATUS"
eq "pinned: no API call is made" 0 "$CALLS"
eq "pinned: it never waits" "" "$SLEEPS"
eq "pinned: the version is the one given" "version=0.45.0
release-tag=v0.45.0" "$OUT"

# --- latest, the first answer is good ----------------------------------------

run_resolve latest "$TOKEN" '{"tag_name":"v0.46.1"}'
eq "latest: the step succeeds" 0 "$STATUS"
eq "latest: one call is enough" 1 "$CALLS"
eq "latest: it never waits" "" "$SLEEPS"
eq "latest: the v is dropped from the version and kept in the tag" "version=0.46.1
release-tag=v0.46.1" "$OUT"
arg_present "latest: it asks the releases API for omni-dev's latest" \
  "https://api.github.com/repos/rust-works/omni-dev/releases/latest"
arg_present "latest: it authenticates with the token" "Authorization: Bearer $TOKEN"
arg_present "latest: it asks for the GitHub JSON media type" "Accept: application/vnd.github+json"
arg_present "latest: it pins the API version" "X-GitHub-Api-Version: 2022-11-28"
lacks "latest: no warning when the first attempt works" "$LOG" "::warning::"
lacks "latest: the token is not printed" "$LOG" "SENTINEL"

run_resolve latest "$TOKEN" '{"tag_name":"0.46.1"}'
eq "latest: a tag with no v gives the same version and tag" "version=0.46.1
release-tag=v0.46.1" "$OUT"

# --- latest with no token: unauthenticated, not an empty header --------------

run_resolve latest "" '{"tag_name":"v0.46.1"}'
eq "no token: the step still succeeds" 0 "$STATUS"
eq "no token: it resolves the version" "version=0.46.1
release-tag=v0.46.1" "$OUT"
lacks "no token: no Authorization header is sent" "$CURLS" "Authorization"
eq "no token: no empty argument stands in for one" 0 "$(grep -c '^$' <<<"$CURLS" || true)"

# --- latest, rate limited, then good -----------------------------------------

run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" '{"tag_name":"v0.46.1"}'
eq "recovers: the step succeeds on the third attempt" 0 "$STATUS"
eq "recovers: it made three calls" 3 "$CALLS"
eq "recovers: it backed off 3s then 6s" "3 6" "$SLEEPS"
eq "recovers: it resolved the version" "version=0.46.1
release-tag=v0.46.1" "$OUT"
has "recovers: attempt 1 is warned about, with GitHub's reason" "$LOG" \
  "::warning::Attempt 1/3: could not resolve latest omni-dev version (API: API rate limit exceeded for 10.0.0.1."
has "recovers: attempt 2 is warned about" "$LOG" "::warning::Attempt 2/3:"
lacks "recovers: attempt 3 worked, so it is not warned about" "$LOG" "Attempt 3/3"
lacks "recovers: no error is raised" "$LOG" "::error::"
lacks "recovers: the token is not printed" "$LOG" "SENTINEL"

# --- latest, never answers ---------------------------------------------------

run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED"
eq "exhausted: the step fails" 1 "$STATUS"
eq "exhausted: it tried three times and no more" 3 "$CALLS"
eq "exhausted: it did not wait after the last attempt" "3 6" "$SLEEPS"
eq "exhausted: it wrote no version" "" "$OUT"
has "exhausted: all three attempts are warned about" "$LOG" "::warning::Attempt 3/3:"
has "exhausted: the error says how many attempts it made" "$LOG" "::error::Could not determine latest omni-dev version from GitHub releases after 3 attempts."
has "exhausted: the error names the input to check" "$LOG" "ensure a github-token is available"
lacks "exhausted: the token is not printed" "$LOG" "SENTINEL"

# Each of these must be retried, not end the step early under -e: curl exiting
# non-zero (a refused connection), a body that is not JSON, and JSON with no tag.
good='{"tag_name":"v0.46.1"}'
expect_retry() { # <name> <first response> <message fragment the warning must carry>
  run_resolve latest "$TOKEN" "$2" "$good"
  eq "$1: the step recovers on the next attempt" 0 "$STATUS"
  eq "$1: it made two calls" 2 "$CALLS"
  eq "$1: it waited 3s" "3" "$SLEEPS"
  eq "$1: it resolved the version" "version=0.46.1
release-tag=v0.46.1" "$OUT"
  has "$1: the warning says what it saw" "$LOG" "::warning::Attempt 1/3: could not resolve latest omni-dev version (API: $3)"

  run_resolve latest "$TOKEN" "$2" "$2" "$2"
  eq "$1: failing every time still ends in the error, not curl's or jq's" 1 "$STATUS"
  has "$1: it reaches the error message" "$LOG" "::error::Could not determine latest omni-dev version"
}
expect_retry "curl fails" '!7' "unknown error"
expect_retry "not JSON" '<html>502 Bad Gateway</html>' "unknown error"
expect_retry "no tag_name" '{}' "no tag_name in response"
expect_retry "null tag_name" '{"tag_name":null}' "no tag_name in response"

# --- the wiring around the script --------------------------------------------

# shellcheck disable=SC2016
has "env: the step reads the token from the github-token input" "$BLOCK" \
  '        GH_TOKEN: ${{ inputs.github-token }}'
# shellcheck disable=SC2016
has "input: github-token defaults to the workflow token" "$(input_block github-token)" \
  '    default: ${{ github.token }}'
eq "input: github-token is optional, so a workflow needs no configuration" "true" \
  "$(input_block github-token | grep -q 'required: false' && echo true || echo false)"

# The runner evaluates every expression in a `run:` script before bash sees it,
# whether it sits in a message or a comment and whether or not a backslash precedes
# it. The token is already in $GH_TOKEN; an expression for it in the text would be
# rewritten to its masked value, so a message could not show the expression it
# meant, and an empty one fails the step before it starts.
# shellcheck disable=SC2016
rest="${RESOLVE//'${{ inputs.version }}'/}"
# shellcheck disable=SC2016
eq "script: the only expression is inputs.version" "" "$(grep -n -F '${{' <<<"$rest" || true)"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
