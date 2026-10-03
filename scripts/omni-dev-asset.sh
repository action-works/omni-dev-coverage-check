#!/usr/bin/env bash
# Print the omni-dev release asset to download for a runner.
#
# Usage: omni-dev-asset.sh <runner.os> <runner.arch>
#   omni-dev-asset.sh Linux ARM64    ->    omni-dev-linux-arm64.tar.gz
#
# The arguments are the values of the `runner.os` (Linux, macOS, Windows) and
# `runner.arch` (X86, X64, ARM, ARM64) contexts.
#
# Exit status:
#   0  the asset name is on stdout
#   1  no release asset is built for that pair; stdout is empty
#   2  a usage error
#
# The pair decides, not the OS alone. Linux used to map to the x86_64 build whatever
# the architecture, so an ARM64 runner downloaded a binary it cannot run and failed
# at "Print omni-dev version", a long way from the step that chose the file. An
# architecture with no asset must be a `1`, never the nearest asset. The Windows
# asset is x86_64; ARM64 keeps taking it, as it always has, because Windows on ARM
# runs x64 binaries under emulation. A 32-bit Windows has nothing it can run.
#
# The names are the ones rust-works/omni-dev's release workflow uploads
# (.github/workflows/release.yml). A new release asset is one more case below.

set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: omni-dev-asset.sh <runner.os> <runner.arch>" >&2
  exit 2
fi

case "$1/$2" in
  Linux/X64) echo "omni-dev-linux.tar.gz" ;;
  Linux/ARM64) echo "omni-dev-linux-arm64.tar.gz" ;;
  macOS/ARM64) echo "omni-dev-macos-arm64.tar.gz" ;;
  Windows/X64 | Windows/ARM64) echo "omni-dev-windows.zip" ;;
  *) exit 1 ;;
esac
