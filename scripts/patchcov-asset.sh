#!/usr/bin/env bash
# Print the patchcov asset for runner.os, runner.arch and a resolved release tag.
# Unsupported platforms (including Windows) exit 1 without choosing another build.
set -uo pipefail
if [ "$#" -ne 3 ]; then
  echo "usage: patchcov-asset.sh <runner.os> <runner.arch> <release-tag>" >&2
  exit 2
fi
case "$1/$2" in
  Linux/X64) target=x86_64-unknown-linux-gnu ;;
  Linux/ARM64) target=aarch64-unknown-linux-gnu ;;
  macOS/X64) target=x86_64-apple-darwin ;;
  macOS/ARM64) target=aarch64-apple-darwin ;;
  *) exit 1 ;;
esac
printf 'patchcov-%s-%s.tar.gz\n' "$3" "$target"
