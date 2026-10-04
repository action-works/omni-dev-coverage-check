#!/usr/bin/env bash
# Tests for tests/llvm-tool-shim.sh. Plain bash, no framework:
#   tests/llvm-tool-shim.test.sh
# Exits non-zero if any case fails.
#
# The shim stands between cargo-llvm-cov and the real llvm tools in the fat-mode
# integration job, and that job's merge count is only as good as the shim: a shim
# that logged nothing would read as "one merge" never, and one that dropped an
# argument or an exit status would fail the action for a reason nobody could see.
# The real tools and `rustc` are stubs here, so this runs anywhere.

set -uo pipefail

SHIM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/llvm-tool-shim.sh"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A sysroot laid out the way `rustc --print target-libdir` reports it:
# <sysroot>/lib/rustlib/<host>/lib, with the llvm tools in ../bin.
host="$work/sysroot/lib/rustlib/host"
mkdir -p "$host/lib" "$host/bin" "$work/bin" "$work/shims"

# Each stub records its own name and arguments, one call per line, and exits with
# $STUB_EXIT (0 when unset), so a test can see what reached the real tool.
for tool in llvm-cov llvm-profdata; do
  cat > "$host/bin/$tool" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_CALLS"
exit "${STUB_EXIT:-0}"
EOF
  chmod +x "$host/bin/$tool"
  ln -s "$SHIM" "$work/shims/$tool"
done

cat > "$work/bin/rustc" <<EOF
#!/usr/bin/env bash
[ "\$*" = "--print target-libdir" ] && echo "$host/lib"
EOF
chmod +x "$work/bin/rustc"

export PATH="$work/bin:$PATH"
export STUB_CALLS="$work/calls.txt"
log="$work/merges.txt"

# run <tool> <args...>: run a shim with the log set; leaves its status in $status.
run() {
  local tool=$1
  shift
  LLVM_SHIM_LOG="$log" "$work/shims/$tool" "$@" > /dev/null 2>&1
  status=$?
}

calls() { cat "$STUB_CALLS" 2>/dev/null; }
merges() { if [ -e "$log" ]; then wc -l < "$log" | tr -d ' '; else echo 0; fi; }
log_file() { if [ -e "$log" ]; then echo present; else echo absent; fi; }

# --- the log does not exist until a merge

run llvm-profdata show profile.profdata
eq "a call that is not a merge logs nothing" 0 "$(merges)"
eq "and leaves no log file" absent "$(log_file)"
eq "that call still reaches the real tool, with its arguments" \
  "llvm-profdata show profile.profdata" "$(calls)"

# --- a merge is logged once per call, and reaches the real tool unchanged

: > "$STUB_CALLS"
run llvm-profdata merge -sparse -f list.txt -o out.profdata
eq "a merge succeeds" 0 "$status"
eq "a merge appends one line to the log" 1 "$(merges)"
eq "the merge reaches the real tool with every argument, in order" \
  "llvm-profdata merge -sparse -f list.txt -o out.profdata" "$(calls)"

run llvm-profdata merge -sparse -f list.txt -o out.profdata
eq "a second merge is a second line" 2 "$(merges)"

# --- only llvm-profdata's merge counts

: > "$STUB_CALLS"
run llvm-cov merge
run llvm-cov export -format=lcov
eq "llvm-cov is never logged, even with a 'merge' argument" 2 "$(merges)"
eq "llvm-cov reaches the real llvm-cov, not the profdata one" \
  "$(printf 'llvm-cov merge\nllvm-cov export -format=lcov')" "$(calls)"

# --- the real tool's exit status is the shim's

STUB_EXIT=3 run llvm-profdata merge -o out.profdata
eq "the real tool's exit status is passed through" 3 "$status"

# --- no log configured: a merge says so instead of running unobserved

: > "$STUB_CALLS"
msg="$(env -u LLVM_SHIM_LOG "$work/shims/llvm-profdata" merge -o out.profdata 2>&1 > /dev/null)"
status=$?
if [ "$status" -ne 0 ] && [[ "$msg" == *LLVM_SHIM_LOG* ]]; then
  ok "a merge with no LLVM_SHIM_LOG fails and names the variable"
else
  bad "a merge with no LLVM_SHIM_LOG fails and names the variable" "status $status: $msg"
fi
eq "and the real tool is not run" "" "$(calls)"

summary
