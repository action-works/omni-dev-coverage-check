#!/usr/bin/env bash
# Combine the per-shard lcov reports of a sharded coverage run into one report.
#
# Used by the `shard-reports` input (thin mode). Everything downstream of this
# step — the diff, the comment, the baseline publish, the line gate — then reads
# one ordinary lcov file, exactly as if a single job had produced it.
#
# Inputs, from the environment so that action inputs never reach a shell as code:
#   SHARD_REPORTS  newline-separated paths or globs of the shard lcov files
#   REPORT         path the combined lcov is written to
#   REPORT_FORMAT  optional; only `lcov`, `auto` or empty make sense for shards
#   RUN_COVERAGE   `true` in fat mode, where the action makes the report itself
#   STRIP_PREFIX   workspace root the shards' paths should sit under
#                  (default: $GITHUB_WORKSPACE)
#   GITHUB_OUTPUT  when set, `count=` and `files=` (comma-separated) are written
#
# Why a plain-text join is safe, and why it must put a newline between shards:
# lcov repeats a file's record once per shard, and consumers union repeated
# records, so concatenation is the merge. But `cargo llvm-cov` writes NO newline
# after its final `end_of_record`, so a bare `cat` glues it onto the next shard's
# first `SF:` line and a consumer can silently drop that file.
#
# A shard that silently produced nothing would otherwise just make coverage look
# slightly worse, so every shard is checked and named when it fails.

set -euo pipefail

fail() {
  echo "::error::$*"
  exit 1
}

[ -n "${SHARD_REPORTS:-}" ] || fail "shard-reports is empty"
[ -n "${REPORT:-}" ] || fail "report is empty"
[ "${RUN_COVERAGE:-false}" != "true" ] ||
  fail "shard-reports needs run-coverage: false; fat mode produces the report itself"
case "${REPORT_FORMAT:-}" in
  '' | auto | lcov) ;;
  *) fail "shard-reports are merged as lcov, but report-format is '${REPORT_FORMAT}'" ;;
esac

# Expand each line as a glob. `compgen -G` expands without word-splitting, so
# paths with spaces work, and a pattern that matches nothing is an error rather
# than a quietly shorter list: a shard that never uploaded must not pass.
shards=()
while IFS= read -r pattern; do
  pattern="${pattern#"${pattern%%[![:space:]]*}"}"
  pattern="${pattern%"${pattern##*[![:space:]]}"}"
  [ -n "$pattern" ] || continue
  matches=()
  while IFS= read -r match; do
    [ -n "$match" ] && matches+=("$match")
  done < <(compgen -G "$pattern" || true)
  [ "${#matches[@]}" -gt 0 ] ||
    fail "shard-reports pattern '$pattern' matched no files; a shard that never uploaded would silently lower coverage"
  shards+=("${matches[@]}")
done <<<"$SHARD_REPORTS"

[ "${#shards[@]}" -gt 0 ] || fail "shard-reports lists no files"

# Sorted and de-duplicated, so the result does not depend on glob order or on
# overlapping patterns.
sorted=()
while IFS= read -r shard; do
  sorted+=("$shard")
done < <(printf '%s\n' "${shards[@]}" | LC_ALL=C sort -u)
shards=("${sorted[@]}")

prefix="${STRIP_PREFIX:-${GITHUB_WORKSPACE:-}}"
prefix="${prefix%/}"

for shard in "${shards[@]}"; do
  [ -f "$shard" ] || fail "shard report '$shard' is not a regular file"
  [ ! "$shard" -ef "$REPORT" ] ||
    fail "report '$REPORT' is also matched by shard-reports ('$shard'); give the combined report a name the patterns do not match"
  [ -s "$shard" ] || fail "shard report '$shard' is empty; its job probably failed"
  grep -q '^DA:' "$shard" ||
    fail "shard report '$shard' has no line records (DA:); its job probably failed or instrumented nothing"

  # Paths are made repo-relative by stripping one workspace prefix. A shard whose
  # absolute paths are ALL elsewhere was measured under another root, and its
  # files would not line up with the diff. A few out-of-tree paths (the standard
  # library) are normal, so only a shard with none in-tree is flagged.
  if [ -n "$prefix" ] && grep -q '^SF:/' "$shard" && ! grep -qF -- "SF:${prefix}/" "$shard"; then
    echo "::warning::shard report '$shard' has no file under '${prefix}'; it was probably measured under a different workspace root, so its files will not line up with the diff. Set strip-prefix, or run every shard under the same root."
  fi
done

mkdir -p "$(dirname -- "$REPORT")"
tmp="$(mktemp "${REPORT}.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
for shard in "${shards[@]}"; do
  cat -- "$shard"
  printf '\n'
done >"$tmp"
# `mktemp` creates the file 0600; a report written any other way is 0644.
chmod -- 644 "$tmp"
mv -- "$tmp" "$REPORT"
trap - EXIT

echo "Combined ${#shards[@]} shard report(s) into $REPORT:"
printf '  %s\n' "${shards[@]}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "count=${#shards[@]}"
    echo "files=$(
      IFS=,
      echo "${shards[*]}"
    )"
  } >>"$GITHUB_OUTPUT"
fi
