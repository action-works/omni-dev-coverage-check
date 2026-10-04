#!/usr/bin/env bash
# A pass-through for llvm-cov and llvm-profdata that counts the profile merges a
# run does, so a test can assert that the action merges once and not once per report
# (#4).
#
# Install it as a symlink named for the tool it stands in for, and point cargo-llvm-cov
# at the symlinks (set both, or cargo-llvm-cov warns that setting one may not work):
#
#   ln -s "$PWD/tests/llvm-tool-shim.sh" "$dir/llvm-cov"
#   ln -s "$PWD/tests/llvm-tool-shim.sh" "$dir/llvm-profdata"
#   export LLVM_COV="$dir/llvm-cov" LLVM_PROFDATA="$dir/llvm-profdata"
#   export LLVM_SHIM_LOG="$PWD/llvm-profdata-merges.txt"
#
# Every `llvm-profdata merge` appends one line to $LLVM_SHIM_LOG; nothing else is
# logged, and the log does not exist until the first merge. Everything runs the real
# tool unchanged.
#
# The real tool is found the way cargo-llvm-cov finds it (the llvm-tools component of
# the active toolchain), at the time of the call, so the shim can be installed before
# the toolchain is.
set -euo pipefail

tool="$(basename "$0")"
real="$(dirname "$(rustc --print target-libdir)")/bin/$tool"

if [ "$tool" = llvm-profdata ] && [ "${1:-}" = merge ]; then
  echo merge >> "${LLVM_SHIM_LOG:?LLVM_SHIM_LOG is not set}"
fi

exec "$real" "$@"
