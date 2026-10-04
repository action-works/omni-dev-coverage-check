#!/usr/bin/env bash
# Tests for the "Resolve omni-dev version" step of action.yml. Plain bash, no
# framework:
#   tests/resolve-version-step.test.sh
# Exits non-zero if any case fails.
#
# The step resolves `version: latest` with one GitHub API call. Run unauthenticated
# from a shared runner IP that call hit the 60/hr limit and failed the whole job (#1),
# so it now sends the token and tries three times. This pins that: the header, the
# retries and their delays, the timeouts that let a hung connection be retried, a
# runner with no jq, and that a pinned version never touches the network and loses a
# leading v (#38) or V, and that one with nothing left after it, or empty, fails with a
# message instead (#51). A spent limit can outlast those attempts, so when all three fail the
# step reads the tag from the github.com releases/latest redirect instead (#40). This
# pins that too: the one request it makes, that only a release tag of omni-dev's own is
# taken from it, and the one error that names both failures when neither answers. The
# step's script is read out of action.yml itself, so renaming the step or moving its
# `run:` fails here, by name, rather than leaving a test of a copy. The script reads the
# version and the token from environment variables its `env:` block fills (nothing is
# substituted into the script text), so a case sets those, and the wiring cases at the
# end check that `env:` fills them.
#
# `curl` is a stub that replays the responses a case scripts, one per call, and logs
# each call's arguments; `sleep` is a stub that logs its argument and returns, so no
# case touches the network or waits. `jq` is the real one, as on the runner.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

if ! command -v jq >/dev/null; then
  echo "FAIL - jq is not installed; the step needs it, as does this test"
  exit 1
fi

STEP_NAME='Resolve omni-dev version'
BLOCK="$(step_block "$STEP_NAME")" || exit 1
RESOLVE="$(step_run "$STEP_NAME")" || exit 1
TOKEN_INPUT="$(input_block github-token)" || exit 1
VERSION_INPUT="$(input_block version)" || exit 1

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
  echo "curl: (${response#!}) stub failure" >&2
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

# run_resolve <version> <token> [response...]: runs the step as the runner would,
# with `VERSION` and `GH_TOKEN` set to <version> and <token> as the step's `env:` does,
# and the responses replayed one per curl call. Sets STATUS (the step's exit status), OUT (the contents of its $GITHUB_OUTPUT),
# LOG (what it printed), CALLS (curl calls made), CURLS (their arguments) and SLEEPS
# (the sleeps asked for, space-separated).
run_resolve() {
  local version=$1 token=$2 dir i=0
  shift 2
  dir="$(mktemp -d "$WORK/case.XXXXXX")"
  : >"$dir/output"
  : >"$dir/curl.log"
  : >"$dir/sleep.log"
  for response in "$@"; do
    i=$((i + 1))
    printf '%s' "$response" >"$dir/response.$i"
  done
  PATH="$BIN:$PATH" CASE_DIR="$dir" GITHUB_OUTPUT="$dir/output" VERSION="$version" GH_TOKEN="$token" \
    bash --noprofile --norc -eo pipefail -c "$RESOLVE" >"$dir/log" 2>&1
  STATUS=$?
  OUT="$(cat "$dir/output")"
  LOG="$(cat "$dir/log")"
  CALLS="$(grep -c '^call ' "$dir/curl.log" || true)"
  CURLS="$(cat "$dir/curl.log")"
  SLEEPS="$(tr '\n' ' ' <"$dir/sleep.log")"
  SLEEPS="${SLEEPS% }"
}

# call_present <name> <call> <arg>: the call received exactly that argument.
call_present() {
  if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "no argument '$3' in: $2"; fi
}

# call_after <name> <call> <flag> <value>: the call received <flag> with <value> next.
call_after() {
  local got
  got="$(grep -A1 -xF -- "$3" <<<"$2" | sed -n 2p)"
  if [ "$got" = "$4" ]; then ok "$1"; else bad "$1" "expected '$3 $4', got '$3 $got' in: $2"; fi
}

# arg_present <name> <arg>: some curl call received exactly that argument.
arg_present() { call_present "$1" "$CURLS" "$2"; }

# arg_after <name> <flag> <value>: a curl call received <flag> with <value> right after.
arg_after() { call_after "$1" "$CURLS" "$2" "$3"; }

# call_args <n>: the arguments of the nth curl call, one per line. The three API
# attempts are calls 1 to 3 and the redirect, when they all fail, is call 4.
call_args() {
  awk -v n="$1" '$0 == "call " n { on = 1; next } /^call / { on = 0 } on' <<<"$CURLS"
}

# --- a pinned version never asks GitHub --------------------------------------

run_resolve 0.45.0 "$TOKEN" '{"tag_name":"v9.9.9"}'
eq "pinned: the step succeeds" 0 "$STATUS"
eq "pinned: no API call is made" 0 "$CALLS"
eq "pinned: it never waits" "" "$SLEEPS"
eq "pinned: the version is the one given" "version=0.45.0
release-tag=v0.45.0" "$OUT"

# --- a pinned version may be spelled as the release tag is (#38) -------------

# Release tags carry a leading v. Left in place it gave `release-tag=vv0.45.0`, a
# download URL that 404s, a cache key of its own, and a `cargo install --version`
# that cargo refuses as not a valid SemVer requirement. So the step drops one
# leading v from the value however it was obtained, and both spellings of a
# release must resolve to the same outputs.
run_resolve v0.45.0 "$TOKEN" '{"tag_name":"v9.9.9"}'
eq "pinned v: the step succeeds" 0 "$STATUS"
eq "pinned v: no API call is made" 0 "$CALLS"
eq "pinned v: it never waits" "" "$SLEEPS"
eq "pinned v: the version has no v and the tag has one" "version=0.45.0
release-tag=v0.45.0" "$OUT"

run_resolve 0.45.0 "$TOKEN"
bare_out="$OUT"
run_resolve v0.45.0 "$TOKEN"
eq "pinned: v0.45.0 and 0.45.0 write identical outputs" "$bare_out" "$OUT"

# Only a leading v goes: a v inside the value is part of it.
run_resolve 0.46.0-dev "$TOKEN"
eq "pinned: a v that is not the first character stays" "version=0.46.0-dev
release-tag=v0.46.0-dev" "$OUT"
run_resolve v0.46.0-dev "$TOKEN"
eq "pinned v: only the leading v is dropped" "version=0.46.0-dev
release-tag=v0.46.0-dev" "$OUT"
# One v, not every leading v: a doubled one is a typo, so it stays visibly wrong
# (a version that starts with v) instead of being quietly accepted.
run_resolve vv0.45.0 "$TOKEN"
eq "pinned v: one leading v is dropped, not all of them" "version=v0.45.0
release-tag=vv0.45.0" "$OUT"

# --- a capital V is accepted too (#51) ---------------------------------------

# A caller may type the tag's v as a capital. It has one reading, so it is dropped
# like the lowercase one and the outputs stay canonical: the version has no v and
# the tag has a lowercase one, as release tags are written. The same cache entry
# and the same download follow.
run_resolve V0.45.0 "$TOKEN" '{"tag_name":"v9.9.9"}'
eq "pinned V: the step succeeds" 0 "$STATUS"
eq "pinned V: no API call is made" 0 "$CALLS"
eq "pinned V: it never waits" "" "$SLEEPS"
eq "pinned V: the version has no V and the tag has a lowercase v" "version=0.45.0
release-tag=v0.45.0" "$OUT"
run_resolve V0.45.0 "$TOKEN"
eq "pinned V: V0.45.0 and 0.45.0 write identical outputs" "$bare_out" "$OUT"
# One character, as for the lowercase v: a mixed pair is a typo and stays visibly wrong.
run_resolve vV0.45.0 "$TOKEN"
eq "pinned V: only one leading character is dropped" "version=V0.45.0
release-tag=vV0.45.0" "$OUT"
run_resolve Vv0.45.0 "$TOKEN"
eq "pinned V: one leading character is dropped, whichever case, not both" "version=v0.45.0
release-tag=vv0.45.0" "$OUT"
# A V that is not the first character is part of the value.
run_resolve 0.46.0-V "$TOKEN"
eq "pinned V: a V that is not the first character stays" "version=0.46.0-V
release-tag=v0.46.0-V" "$OUT"

# --- a value that names no release fails at the step (#51) -------------------

# Nothing is left of `v` or `V` once the leading character goes, and an empty
# value never had one. Left to pass, the step succeeded with an empty `version`
# output (a cache key ending `--binary`) and `release-tag=v`, and the failure came
# later, in the platform step, which blamed the release ("omni-dev v has no
# pre-built ...") rather than the input. So the step stops with one message that
# names the input and both ways out, before it writes either output. The empty
# string is how the script sees `version: ''`; whether a workflow's empty value
# reaches it, or the input's default applies instead, is what the integration
# workflow's `version-input` job shows on a runner.
expect_no_release() { # <name> <version as the script sees it> <value the message quotes>
  run_resolve "$2" "$TOKEN" '{"tag_name":"v9.9.9"}'
  eq "$1: the step fails" 1 "$STATUS"
  eq "$1: it writes no output, so no empty version reaches a later step" "" "$OUT"
  eq "$1: no API call is made, so the default is not looked up" 0 "$CALLS"
  eq "$1: it never waits" "" "$SLEEPS"
  # Non-empty lines: a here-string of an empty log is one empty line, which a plain
  # line count would call one message.
  eq "$1: it logs one error and nothing else" 1 "$(grep -c . <<<"$LOG" || true)"
  has "$1: the error names the input" "$LOG" "::error::The 'version' input"
  has "$1: the error quotes what it was given" "$LOG" "(got '$3')"
  has "$1: the error offers a release number" "$LOG" "a release number such as 0.45.0"
  has "$1: the error offers latest" "$LOG" "or to 'latest'"
  lacks "$1: the token is not printed" "$LOG" "SENTINEL"
}
expect_no_release "empty" "" ""
expect_no_release "v alone" v v
expect_no_release "V alone" V V

# The check sits after the `latest` branch, so it holds however the value was obtained,
# as the strip does: a tag that is only a v would otherwise write an empty version.
# GitHub publishes no such tag, so this pins where the check sits, not a case a caller
# can reach (the message then blames the input, which is as close as the step can say).
run_resolve latest "$TOKEN" '{"tag_name":"v"}'
eq "latest resolving to a lone v: the step fails" 1 "$STATUS"
eq "latest resolving to a lone v: it writes no output" "" "$OUT"
has "latest resolving to a lone v: it logs the refusal" "$LOG" "::error::The 'version' input names no release (got 'v')"

# --- a value with a character a release is not written with fails at the step (#72) ----

# The value goes into the step's outputs, a cache key, the download URL and
# `cargo install --version`. A newline wrote extra lines into the outputs (so an input
# could set `release-tag`), and `/..` walked the download URL out of omni-dev's release
# path, where curl resolves the dot segments. Each refused value must fail the step with
# one message, write NOTHING (a refusal that still wrote `version=` would pass an exit
# status check), and make no request. The message shows the value with what is not
# printable replaced, so a newline in it cannot start a second workflow command, and cuts
# a long one short. The allowlist is letters, digits and . + - * ^ ~ < > = , space.
expect_bad_char() { # <name> <version as the script sees it> <value the message quotes>
  run_resolve "$2" "$TOKEN" '{"tag_name":"v9.9.9"}'
  eq "$1: the step fails" 1 "$STATUS"
  eq "$1: it writes no output" "" "$OUT"
  eq "$1: no API call is made" 0 "$CALLS"
  eq "$1: it never waits" "" "$SLEEPS"
  # Non-empty lines: a newline in the value must not make a second line of the log.
  eq "$1: it logs one error and nothing else, whatever the value held" 1 "$(grep -c . <<<"$LOG" || true)"
  has "$1: the error names the input and the problem" "$LOG" \
    "::error::The 'version' input holds a character that a release number is not written with"
  has "$1: the error quotes what it was given, printable" "$LOG" "(got '$3')"
  has "$1: the error offers a release number" "$LOG" "a release number such as 0.45.0"
  has "$1: the error offers latest" "$LOG" "or to 'latest'"
  lacks "$1: the token is not printed" "$LOG" "SENTINEL"
}
expect_bad_char "a newline then an injected release-tag" $'0.45.0\nrelease-tag=vEVIL' '0.45.0?release-tag=vEVIL'
expect_bad_char "a newline then an output the action never sets" $'0.45.0\nsomething=else' '0.45.0?something=else'
expect_bad_char "a newline then a workflow command" $'0.45.0\n::error::forged' '0.45.0?::error::forged'
expect_bad_char "a trailing newline" $'0.45.0\n' '0.45.0?'
expect_bad_char "a carriage return" $'0.45.0\r' '0.45.0?'
expect_bad_char "a tab" $'0.45.0\t1' '0.45.0?1'
expect_bad_char "a path that leaves omni-dev's releases (three ..)" '0.45.0/../../../evil/repo/releases/download/v9' \
  '0.45.0/../../../evil/repo/releases/download/v9'
expect_bad_char "a path that leaves the repository" '0/../../../other/repo/releases/download/v1' \
  '0/../../../other/repo/releases/download/v1'
expect_bad_char "a slash alone" 'a/b' 'a/b'
expect_bad_char "a slash after the strip" 'v/x' 'v/x'
expect_bad_char "an escaped dot segment" '%2e%2e' '%2e%2e'
expect_bad_char "an escaped slash" '0.45.0%2f..' '0.45.0%2f..'
expect_bad_char "a query" '0.45.0?x' '0.45.0?x'
expect_bad_char "a fragment" '0.45.0#x' '0.45.0#x'
expect_bad_char "a double quote" '0.45.0"' '0.45.0"'
expect_bad_char "a single quote" "0.45.0'" "0.45.0'"
# The next two are literal text for the step to refuse, never meant to expand.
# shellcheck disable=SC2016
expect_bad_char "a backtick" '0.45.0`id`' '0.45.0`id`'
# shellcheck disable=SC2016
expect_bad_char "a command substitution" '0.45.0$(id)' '0.45.0$(id)'
expect_bad_char "a semicolon" '0.45.0;id' '0.45.0;id'
expect_bad_char "a pipe" '0.45.0|id' '0.45.0|id'
expect_bad_char "an ampersand" '0.45.0&id' '0.45.0&id'
expect_bad_char "a backslash" '0.45.0\n' '0.45.0\n'
long="$(printf 'x/%.0s' {1..40})"
expect_bad_char "a long value is cut short" "$long" "${long:0:60}..."

# A non-ASCII letter is refused too. What the message shows for it depends on the locale
# (printable in a UTF-8 one), so only the refusal is pinned.
run_resolve '0.45.0é' "$TOKEN"
eq "a non-ASCII letter: the step fails" 1 "$STATUS"
eq "a non-ASCII letter: it writes no output" "" "$OUT"

# What is accepted, as before: a release, with or without its v, a pre-release, build
# metadata, and the version requirements `cargo install --version` takes, which the source
# install has always accepted (the release-tag of a requirement is not a tag that exists,
# so the pre-built path reports a missing asset for it, as it did).
accepts() { # <name> <version> <the version output>
  run_resolve "$2" "$TOKEN" '{"tag_name":"v9.9.9"}'
  eq "$1: the step succeeds" 0 "$STATUS"
  eq "$1: the outputs are the version and its tag" "version=$3
release-tag=v$3" "$OUT"
  eq "$1: no API call is made" 0 "$CALLS"
  eq "$1: it logs nothing" "" "$LOG"
}
accepts "a release" 0.45.0 0.45.0
accepts "a release tag" v0.45.0 0.45.0
accepts "a capital V" V0.45.0 0.45.0
accepts "a pre-release" 0.46.0-rc.1 0.46.0-rc.1
accepts "a dev pre-release" 0.46.0-dev 0.46.0-dev
accepts "build metadata" '0.46.0+build.5' '0.46.0+build.5'
accepts "a caret requirement" '^0.45' '^0.45'
accepts "a tilde requirement" '~0.45.1' '~0.45.1'
accepts "a comparison" '>=0.45' '>=0.45'
accepts "an exact requirement" '=0.45.0' '=0.45.0'
accepts "a wildcard" '0.45.*' '0.45.*'
accepts "a range, with a comma and spaces" '>= 0.45, < 0.47' '>= 0.45, < 0.47'

# The check sits after the `latest` branch, as the strip does, so a tag the API gave is
# held to it too. GitHub publishes no such tag; this pins where the check sits.
run_resolve latest "$TOKEN" '{"tag_name":"v0.46.0/../../x"}'
eq "latest resolving to a tag with slashes: the step fails" 1 "$STATUS"
eq "latest resolving to a tag with slashes: it writes no output" "" "$OUT"
has "latest resolving to a tag with slashes: it logs the refusal" "$LOG" \
  "::error::The 'version' input holds a character that a release number is not written with"
run_resolve latest "$TOKEN" '{"tag_name":"v0.46.0\nrelease-tag=vEVIL"}'
eq "latest resolving to a tag with a newline: the step fails" 1 "$STATUS"
eq "latest resolving to a tag with a newline: it writes no output" "" "$OUT"
run_resolve latest "$TOKEN" '{"tag_name":"v0.46.0-rc.1"}'
eq "latest resolving to a pre-release tag: the step succeeds" 0 "$STATUS"
eq "latest resolving to a pre-release tag: the outputs are its own" "version=0.46.0-rc.1
release-tag=v0.46.0-rc.1" "$OUT"

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
arg_after "latest: it bounds the connection, so a hang is retried" --connect-timeout 10
arg_after "latest: it bounds the whole call, so a hang is retried" --max-time 30
# With --fail curl drops the body of a 403, and GitHub's reason with it: the warning
# would say "unknown error" for a rate limit.
eq "latest: curl is not told to --fail, so GitHub's reason stays in the body" 0 \
  "$(grep -cE '^(--fail|-[A-Za-z]*f[A-Za-z]*)$' <<<"$CURLS" || true)"
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

# A fourth response, a redirect to another release, is scripted and must stay unread:
# the redirect only changes a run that would have failed.
run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" '{"tag_name":"v0.46.1"}' \
  "302 https://github.com/rust-works/omni-dev/releases/tag/v9.9.9"
eq "recovers: the step succeeds on the third attempt" 0 "$STATUS"
eq "recovers: it made three calls, so the redirect was not asked" 3 "$CALLS"
eq "recovers: it backed off 3s then 6s" "3 6" "$SLEEPS"
eq "recovers: it resolved the version" "version=0.46.1
release-tag=v0.46.1" "$OUT"
has "recovers: attempt 1 is warned about, with GitHub's reason" "$LOG" \
  "::warning::Attempt 1/3: could not resolve latest omni-dev version (API: API rate limit exceeded for 10.0.0.1."
has "recovers: attempt 2 is warned about" "$LOG" "::warning::Attempt 2/3:"
lacks "recovers: attempt 3 worked, so it is not warned about" "$LOG" "Attempt 3/3"
lacks "recovers: no error is raised" "$LOG" "::error::"
lacks "recovers: the token is not printed" "$LOG" "SENTINEL"

# --- latest, the API never answers: the redirect -----------------------------

TAG_URL=https://github.com/rust-works/omni-dev/releases/tag

run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "302 $TAG_URL/v0.46.1"
eq "redirect: the step succeeds" 0 "$STATUS"
eq "redirect: three API attempts, then one request for the redirect and no more" 4 "$CALLS"
eq "redirect: it waited between the API attempts only" "3 6" "$SLEEPS"
eq "redirect: the version comes from the tag in the Location" "version=0.46.1
release-tag=v0.46.1" "$OUT"
has "redirect: attempt 3 is still warned about" "$LOG" "::warning::Attempt 3/3:"
has "redirect: a warning says the redirect answered and why the API did not" "$LOG" \
  "::warning::The GitHub API gave no release after 3 attempts (API: API rate limit exceeded for 10.0.0.1."
has "redirect: the warning names the release it resolved" "$LOG" \
  "was resolved from the github.com releases/latest redirect instead: v0.46.1."
has "redirect: the warning offers the ways out, since the job passed on a failing API" "$LOG" \
  "or set 'version' to a release to skip the lookup."
lacks "redirect: no error is raised" "$LOG" "::error::"
lacks "redirect: the token is not printed" "$LOG" "SENTINEL"

call="$(call_args 4)"
call_present "redirect: it asks the releases/latest page" "$call" \
  "https://github.com/rust-works/omni-dev/releases/latest"
call_after "redirect: it asks curl for the status and the Location" "$call" -w '%{http_code} %{redirect_url}'
call_after "redirect: it keeps the page itself" "$call" -o /dev/null
call_after "redirect: it bounds the connection, so a hang ends in the error" "$call" --connect-timeout 10
call_after "redirect: it bounds the whole call, so a hang ends in the error" "$call" --max-time 30
# Following the redirect would fetch the tag's page, which the step has no use for.
eq "redirect: it does not follow the redirect" 0 \
  "$(grep -cE '^(--location|-[A-Za-z]*L[A-Za-z]*)$' <<<"$call" || true)"
# The token buys nothing on github.com, so it is not sent there.
lacks "redirect: no token is sent to github.com" "$call" "Authorization"
lacks "redirect: no token is sent to github.com, even as an argument" "$call" "SENTINEL"

# Whatever the tag is, it is taken from the Location, and a pre-release suffix is a tag.
run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "302 $TAG_URL/v10.20.300"
eq "redirect: a tag of several digits is taken whole" "version=10.20.300
release-tag=v10.20.300" "$OUT"
run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "302 $TAG_URL/v0.46.1-rc.1"
eq "redirect: a pre-release suffix is part of the tag" "version=0.46.1-rc.1
release-tag=v0.46.1-rc.1" "$OUT"
run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "302 $TAG_URL/v1.0.0-rc-1.x-2"
eq "redirect: a pre-release identifier may hold a hyphen, as in semver" "version=1.0.0-rc-1.x-2
release-tag=v1.0.0-rc-1.x-2" "$OUT"

run_resolve latest "" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "302 $TAG_URL/v0.46.1"
eq "redirect, no token: the step succeeds" 0 "$STATUS"
eq "redirect, no token: it resolves the version" "version=0.46.1
release-tag=v0.46.1" "$OUT"

# --- latest, the API and the redirect both fail ------------------------------

# A redirect that is not a release tag of this repository is rejected, not used: the
# value reaches a cache key, a download URL, cargo install and $GITHUB_OUTPUT. Each
# case must end in the one error, with the three API attempts and one request for the
# redirect made, and nothing written for the steps after it.
expect_failure() { # <name> <redirect response> <what the error says the redirect gave>
  run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "$2"
  eq "$1: the step fails" 1 "$STATUS"
  eq "$1: it asked the redirect once" 4 "$CALLS"
  eq "$1: it wrote no version" "" "$OUT"
  has "$1: the error says what the redirect gave" "$LOG" \
    "the github.com releases/latest redirect gave no release tag ($3)."
  lacks "$1: it does not say the redirect answered" "$LOG" "was resolved from"
  lacks "$1: the token is not printed" "$LOG" "SENTINEL"
}
expect_location() { # <name> <the Location a 302 carries>
  expect_failure "$1" "302 $2" "HTTP 302 to $2"
}

expect_failure "redirect fails: curl cannot connect" '!7' "HTTP 000"
expect_failure "redirect fails: curl times out" '!28' "HTTP 000"
expect_failure "redirect fails: the page is served, not redirected" '200 ' "HTTP 200"
expect_failure "redirect fails: github.com throttles it" '429 ' "HTTP 429"
expect_failure "redirect fails: a server error" '502 ' "HTTP 502"
expect_failure "redirect fails: no answer at all" '' "HTTP 000"
expect_location "redirect fails: a login page" "https://github.com/login?return_to=%2Frust-works%2Fomni-dev%2Freleases%2Flatest"
expect_location "redirect fails: the latest page itself" "https://github.com/rust-works/omni-dev/releases/latest"
expect_location "redirect fails: the tags page" "https://github.com/rust-works/omni-dev/releases/tag/"
expect_location "redirect fails: another repository" "https://github.com/someone-else/omni-dev/releases/tag/v0.46.1"
expect_location "redirect fails: another host" "https://example.com/rust-works/omni-dev/releases/tag/v0.46.1"
expect_location "redirect fails: not https" "http://github.com/rust-works/omni-dev/releases/tag/v0.46.1"
expect_location "redirect fails: github.com as a suffix of another host" "https://github.com.example.com/rust-works/omni-dev/releases/tag/v0.46.1"
# The dot in the host is a dot, not any character.
expect_location "redirect fails: a host that differs from github.com by one character" "https://githubxcom/rust-works/omni-dev/releases/tag/v0.46.1"
expect_location "redirect fails: a tag that is not a version" "$TAG_URL/nightly"
expect_location "redirect fails: a tag with a major only" "$TAG_URL/v1"
expect_location "redirect fails: a tag with no patch" "$TAG_URL/v1.2"
expect_location "redirect fails: a tag with four numbers" "$TAG_URL/v1.2.3.4"
expect_location "redirect fails: a tag with no v" "$TAG_URL/0.46.1"
expect_location "redirect fails: a tag with a letter in a number" "$TAG_URL/v0.46.1x"
expect_location "redirect fails: a tag with a dangling hyphen" "$TAG_URL/v0.46.1-"
expect_location "redirect fails: a tag with build metadata" "$TAG_URL/v0.46.1+build"
expect_location "redirect fails: a path below the tag" "$TAG_URL/v0.46.1/extra"
expect_location "redirect fails: a query after the tag" "$TAG_URL/v0.46.1?x=1"
expect_location "redirect fails: a fragment after the tag" "$TAG_URL/v0.46.1#x"
# A valid tag URL inside a longer string is not the Location itself.
expect_location "redirect fails: a tag URL in the query of another URL" "https://example.com/?u=$TAG_URL/v0.46.1"
expect_location "redirect fails: a tag URL after leading text" "x$TAG_URL/v0.46.1"
# The version's dots are dots, and the suffix is a semver pre-release and nothing else.
expect_location "redirect fails: a letter where a dot belongs" "$TAG_URL/v1x2y3"
expect_location "redirect fails: a suffix that is a command" "$TAG_URL/v0.46.1-x;id"
expect_location "redirect fails: a suffix of one dot" "$TAG_URL/v0.46.1-."
expect_location "redirect fails: a suffix with an empty identifier" "$TAG_URL/v0.46.1-rc..1"
expect_location "redirect fails: a suffix that ends in a dot" "$TAG_URL/v0.46.1-rc."
expect_location "redirect fails: a suffix with an escaped newline" "$TAG_URL/v0.46.1-%0A"
expect_location "redirect fails: a newline smuggled in, escaped" "$TAG_URL/v0.46.1%0Aversion=9.9.9"
expect_location "redirect fails: a command after the tag" "$TAG_URL/v0.46.1;id"

# The one error names both failures and both ways out.
run_resolve latest "$TOKEN" "$RATE_LIMITED" "$RATE_LIMITED" "$RATE_LIMITED" "429 "
has "both fail: the error says the API gave no release, after how many attempts" "$LOG" \
  "::error::Could not determine latest omni-dev version. The GitHub API gave no release after 3 attempts"
has "both fail: the error carries the API's reason" "$LOG" \
  "(API: API rate limit exceeded for 10.0.0.1."
has "both fail: the error says what the redirect gave" "$LOG" \
  "and the github.com releases/latest redirect gave no release tag (HTTP 429)."
has "both fail: the error names the input to check" "$LOG" "check that github-token holds a valid token"
has "both fail: the error offers pinning, which skips the lookup" "$LOG" "or set 'version' to a release to skip the lookup."
eq "both fail: it waited between the API attempts only" "3 6" "$SLEEPS"
has "both fail: all three API attempts are warned about" "$LOG" "::warning::Attempt 3/3:"
eq "both fail: a single error is raised" 1 "$(grep -c '^::error::' <<<"$LOG" || true)"

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

  run_resolve latest "$TOKEN" "$2" "$2" "$2" "429 "
  eq "$1: failing every time still ends in the error, not curl's or jq's" 1 "$STATUS"
  has "$1: it reaches the error message" "$LOG" "::error::Could not determine latest omni-dev version"
}
expect_retry "curl fails" '!7' "unknown error"
expect_retry "curl times out" '!28' "unknown error"
expect_retry "not JSON" '<html>502 Bad Gateway</html>' "unknown error"
expect_retry "no tag_name" '{}' "no tag_name in response"
expect_retry "null tag_name" '{"tag_name":null}' "no tag_name in response"

# --- a runner with no jq ------------------------------------------------------

# The step's jq calls hide their errors, so without a guard a missing jq looks like
# a rate limit: three retries, then advice about the token. The guard runs before
# any call, so the step needs nothing on PATH but the shell itself; an empty
# directory stands in for a runner that lacks jq.
nojq="$WORK/nojq"
mkdir "$nojq"
dir="$(mktemp -d "$WORK/case.XXXXXX")"
: >"$dir/output"
LOG="$(PATH="$nojq" GITHUB_OUTPUT="$dir/output" VERSION=latest GH_TOKEN="$TOKEN" "$BASH" --noprofile --norc -eo pipefail -c "$RESOLVE" 2>&1)"
STATUS=$?
eq "no jq: the step fails" 1 "$STATUS"
has "no jq: the error says jq is missing" "$LOG" "::error::jq is required to resolve 'version: latest'"
has "no jq: the error offers pinning" "$LOG" "set 'version' to a release to skip the lookup"
lacks "no jq: it is not mistaken for a rate limit" "$LOG" "::warning::"
eq "no jq: it wrote no version" "" "$(cat "$dir/output")"

# --- the wiring around the script --------------------------------------------

# The cases above run the script under bash; it uses arrays, which sh and pwsh lack.
has "shell: the step runs under bash, as these cases do" "$BLOCK" "      shell: bash"
# shellcheck disable=SC2016
has "env: the step reads the version from the version input" "$BLOCK" \
  '        VERSION: ${{ inputs.version }}'
# shellcheck disable=SC2016
has "env: the step reads the token from the github-token input" "$BLOCK" \
  '        GH_TOKEN: ${{ inputs.github-token }}'
# shellcheck disable=SC2016
has "input: github-token defaults to the workflow token" "$TOKEN_INPUT" \
  '    default: ${{ github.token }}'
has "input: github-token is optional, so a workflow needs no configuration" \
  "$TOKEN_INPUT" "    required: false"
# The v is accepted, so the input must say so: a caller who copies a release tag
# should not have to read the script to learn it works. The capital is accepted
# too (#51), and the input says that, not only "a leading v".
has "input: version says a leading v or V is accepted" "$VERSION_INPUT" \
  "with or without a leading v or V (e.g., 0.45.0 or v0.45.0)"

# The runner evaluates every expression in a `run:` script before bash sees it,
# whether it sits in a message or a comment and whether or not a backslash precedes
# it. The token is already in $GH_TOKEN and the version in $VERSION; an expression for
# either in the text would be rewritten to its value (masked, for the token), so a
# message could not show the expression it meant, and an empty one fails the step
# before it starts. A value that holds shell syntax would also run as shell.
# shellcheck disable=SC2016
eq "script: it holds no expression" "" "$(grep -n -F '${{' <<<"$RESOLVE" || true)"

summary
