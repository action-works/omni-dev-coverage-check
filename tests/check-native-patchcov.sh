#!/usr/bin/env bash
# Exercise real patchcov against the README used by the Integration reports.
# Documentation can accidentally introduce malformed coverage markers, which
# stub-based step tests cannot detect. Run after installing patchcov, from the root.
set -euo pipefail
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'SF:%s/README.md\nDA:1,1\nDA:2,0\nDA:3,1\nDA:4,0\nend_of_record\n' "$PWD" > "$work/report.lcov"
patchcov diff --report "$work/report.lcov" --base-ref HEAD -o markdown > "$work/comment.md"
patchcov diff --report "$work/report.lcov" --base-ref HEAD -o json > "$work/report.json"
jq -e 'type == "object"' "$work/report.json" > /dev/null
patchcov diff --report "$work/report.lcov" --base-ref HEAD --ignore-filename-regex '^README[.]md$' -o json > "$work/filtered.json"
jq -e '.excluded_files.paths == ["README.md"] and .patch_coverage.files == []' "$work/filtered.json" > /dev/null
patchcov diff --report "$work/report.lcov" --base-ref HEAD --fail-under-lines 50 -o json > /dev/null
rc=0
patchcov diff --report "$work/report.lcov" --base-ref HEAD --fail-under-lines 100 -o json > /dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ]
echo 'ok   - real patchcov reads README fixtures, reports exclusions and enforces the line gate'
