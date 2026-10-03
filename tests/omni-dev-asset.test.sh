#!/usr/bin/env bash
# Tests for scripts/omni-dev-asset.sh. Plain bash, no framework:
#   tests/omni-dev-asset.test.sh
# Exits non-zero if any case fails.
#
# Every (OS, arch) pair the runner contexts can hold is pinned, not just the ones
# with an asset: the bug this guards against was a pair with no asset (Linux ARM64)
# quietly receiving another's (Linux x86_64).

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/omni-dev-asset.sh"

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

# asset <os> <arch> <expected asset>: the script prints exactly that and exits 0.
asset() {
  local os=$1 arch=$2 want=$3 out status
  out="$(bash "$SCRIPT" "$os" "$arch" 2>/dev/null)"
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
  out="$(bash "$SCRIPT" "$os" "$arch" 2>/dev/null)"
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

asset Linux X64 omni-dev-linux.tar.gz
asset Linux ARM64 omni-dev-linux-arm64.tar.gz
asset macOS ARM64 omni-dev-macos-arm64.tar.gz
asset Windows X64 omni-dev-windows.zip
# Unchanged from before: Windows on ARM runs the x86_64 asset under emulation.
asset Windows ARM64 omni-dev-windows.zip

# --- the pairs without one --------------------------------------------------

# Linux used to take the x86_64 build whatever the architecture. These are the
# self-hosted architectures it would have been wrong for.
none Linux X86
none Linux ARM
none macOS X64
none macOS X86
none Windows X86
none Windows ARM
none FreeBSD X64

# --- the regression, stated directly ----------------------------------------

arm="$(bash "$SCRIPT" Linux ARM64 2>/dev/null)"
x64="$(bash "$SCRIPT" Linux X64 2>/dev/null)"
if [ -n "$arm" ] && [ "$arm" != "$x64" ]; then
  ok "Linux ARM64 does not get the x86_64 build"
else
  bad "Linux ARM64 does not get the x86_64 build" "ARM64 '$arm', X64 '$x64'"
fi

# --- usage ------------------------------------------------------------------

usage
usage Linux
usage Linux ARM64 extra

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
