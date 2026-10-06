#!/usr/bin/env bash
# Tests for scripts/patchcov-asset.sh. Plain bash, no framework:
#   tests/patchcov-asset.test.sh
# Exits non-zero if any case fails.
#
# Every (OS, arch) pair the runner contexts can hold is pinned, not just the ones
# with an asset: the bug this guards against was a pair with no asset (Linux ARM64)
# quietly receiving another's (Linux x86_64).

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/patchcov-asset.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

# asset <os> <arch> <expected asset>: the script prints exactly that and exits 0.
asset() {
  local os=$1 arch=$2 want=$3 out status
  out="$(bash "$SCRIPT" "$os" "$arch" v0.1.1 2>/dev/null)"
  status=$?
  if [ "$status" -eq 0 ] && [ "$out" = "$want" ]; then
    ok "$os $arch -> $want"
  else
    bad "$os $arch -> $want" "got status $status, output '$out'"
  fi
}

# none <os> <arch>: no asset exists, so nothing is printed and the status is 1.
none() {
  local os=$1 arch=$2 out status
  out="$(bash "$SCRIPT" "$os" "$arch" v0.1.1 2>/dev/null)"
  status=$?
  if [ "$status" -eq 1 ] && [ -z "$out" ]; then
    ok "$os $arch -> no asset"
  else
    bad "$os $arch -> no asset" "got status $status, output '$out'"
  fi
}

# usage <args...>: a wrong argument count is a usage error (2) with nothing printed.
usage() {
  local out status
  out="$(bash "$SCRIPT" "$@" 2>/dev/null)"
  status=$?
  if [ "$status" -eq 2 ] && [ -z "$out" ]; then
    ok "usage error for $# argument(s)"
  else
    bad "usage error for $# argument(s)" "got status $status, output '$out'"
  fi
}

# --- the pairs with an asset ------------------------------------------------

asset Linux X64 patchcov-v0.1.1-x86_64-unknown-linux-gnu.tar.gz
asset Linux ARM64 patchcov-v0.1.1-aarch64-unknown-linux-gnu.tar.gz
asset macOS X64 patchcov-v0.1.1-x86_64-apple-darwin.tar.gz
asset macOS ARM64 patchcov-v0.1.1-aarch64-apple-darwin.tar.gz
for os in Linux macOS Windows; do
  none "$os" X86
  none "$os" ARM
done
none Windows X64
none Windows ARM64
none FreeBSD X64

# --- the regression, stated directly ----------------------------------------

arm="$(bash "$SCRIPT" Linux ARM64 v0.1.1 2>/dev/null)"
x64="$(bash "$SCRIPT" Linux X64 v0.1.1 2>/dev/null)"
if [ -n "$arm" ] && [ "$arm" != "$x64" ]; then
  ok "Linux ARM64 does not get the x86_64 build"
else
  bad "Linux ARM64 does not get the x86_64 build" "ARM64 '$arm', X64 '$x64'"
fi

# --- usage ------------------------------------------------------------------

usage
usage Linux
usage Linux ARM64 v0.1.1 extra

summary
