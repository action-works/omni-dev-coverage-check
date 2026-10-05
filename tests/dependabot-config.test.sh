#!/usr/bin/env bash
# Tests for .github/dependabot.yml (#58). Plain bash, no framework:
#   tests/dependabot-config.test.sh
# Exits non-zero if any case fails.
#
# Dependabot opens a pull request for each action pin that is behind, and its commit message
# has to pass the required `Validate Commit Messages` (omni-dev lints each commit, errors
# fail it). Its default, `chore(deps): ...`, does not: `deps` is not a scope of this project.
# The check cannot be fixed on a bot's pull request afterwards (the commit is already
# written), so the config is held to what the lint needs: a prefix whose type is one the
# guidelines list and whose scopes are all in .omni-dev/scopes.yaml, and a subject that stays
# inside 72 characters for the longest action this repository uses, with two-digit versions.
# The lint itself was run on Dependabot's real message shape once, by hand, with omni-dev
# 0.45.0 (`ci(ci)` on a change to action.yml passes, `chore(deps)` fails on its scope).
#
# The config is read with awk for the layout it has (an entry at 2 spaces, its keys at 4, the
# prefix at 6) and refuses another, as tests/merge-queue.test.sh does for the workflows. The
# real file is checked, and copies broken one way at a time must each be reported.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# The longest a subject may be: the project's own rule (a 73-character subject is over it).
MAX_SUBJECT=72

# updates_of <config>: one line per entry of `updates:`, `<ecosystem>|<directory>|<prefix>`
# (a field the entry lacks is empty), quotes taken off. Refuses a file with no `updates:`.
updates_of() {
  awk '
    function flush() { if (eco != "") print eco "|" dir "|" prefix; eco = ""; dir = ""; prefix = "" }
    function value(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]*(#.*)?$/, "", s); gsub(/^"|"$/, "", s); return s }
    /^updates:[ \t]*$/ { seen = 1; next }
    seen && /^[^ \t#]/ { flush(); seen = 0 }
    seen && /^  - package-ecosystem:/ { flush(); eco = value($0); n++; next }
    seen && /^    directory:/ { dir = value($0); next }
    seen && /^      prefix:/ { prefix = value($0); next }
    END { flush(); if (!n) { print "no entry under a top-level `updates:`" > "/dev/stderr"; exit 1 } }
  ' "$1"
}

# uses_names: the `owner/repo` of every action the action and the workflows use, one per
# line, once each. Local actions (`./`) and refs that are not a version are left out: there
# is nothing for Dependabot to bump.
uses_names() {
  grep -hE '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^./ ][^@ ]*@' "$ROOT/action.yml" "$ROOT"/.github/workflows/*.yml \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/@.*//' \
    | awk -F/ '{ print $1 "/" $2 }' | sort -u
}

# config_problems <config>: one line per problem, nothing if there is none.
config_problems() {
  local cfg=$1 err="$WORK/reader.err" rows row dir prefix type scopes scope name longest=0 len subject
  grep -Fxq 'version: 2' "$cfg" || echo "the config is not 'version: 2'"
  if ! rows="$(updates_of "$cfg" 2>"$err")"; then
    echo "cannot read the updates: $(<"$err")"
    return
  fi
  row="$(grep '^github-actions|' <<<"$rows" | head -n1)"
  if [ -z "$row" ]; then
    echo "no github-actions entry: the pins would not be kept current"
    return
  fi
  IFS='|' read -r _ dir prefix <<<"$row"
  [ "$dir" = / ] || echo "the github-actions entry reads directory '$dir', not '/': action.yml and the workflows are at the root"
  if [ -z "$prefix" ]; then
    echo "the github-actions entry sets no commit-message prefix: Dependabot's default scope, deps, fails the lint"
    return
  fi
  # `type(scope[,scope])`: the prefix as the lint reads it, once Dependabot adds `: bump ...`.
  if ! [[ "$prefix" =~ ^([a-z]+)\(([a-z,]+)\)$ ]]; then
    echo "the prefix '$prefix' is not of the form type(scope)"
    return
  fi
  type="${BASH_REMATCH[1]}"
  scopes="${BASH_REMATCH[2]}"
  grep -Fq "| \`$type\`" "$ROOT/.omni-dev/commit-guidelines.md" || echo "the prefix's type '$type' is not a type of .omni-dev/commit-guidelines.md"
  for scope in ${scopes//,/ }; do
    grep -Fxq "  - name: \"$scope\"" "$ROOT/.omni-dev/scopes.yaml" || echo "the prefix's scope '$scope' is not in .omni-dev/scopes.yaml"
  done
  # The subject Dependabot writes: `<prefix>: bump <owner/repo> from <a> to <b>`, with two-digit
  # versions as the worst case this repository will see for a while.
  while IFS= read -r name; do
    subject="$prefix: bump $name from 99 to 100"
    len=${#subject}
    [ "$len" -le "$longest" ] || longest=$len
    [ "$len" -le "$MAX_SUBJECT" ] || echo "the subject for $name would be $len characters ($subject), over $MAX_SUBJECT"
  done <<<"$(uses_names)"
  [ "$longest" -gt 0 ] || echo "no action found to measure a subject for"
}

CONFIG="$ROOT/.github/dependabot.yml"
pass "the config exists" test -f "$CONFIG"
eq "the real config: no problem" "" "$(config_problems "$CONFIG")"

# The readers on the real data: the entry, and what is measured.
eq "the real config: one github-actions entry, at the root, with the prefix" "github-actions|/|ci(ci)" "$(updates_of "$CONFIG")"
pass "the actions measured include the longest one in use" grep -Fxq 'marocchino/sticky-pull-request-comment' <(uses_names)
lacks "a local action is not measured" "$(uses_names)" "./"

# Each way to break it, on a copy of the real file, must be reported. Every edit is checked to
# have changed the copy: a no-op would pass for the wrong reason.
mutant=0
# mutate <name> <sed program> <fragment the problems must hold>
mutate() {
  local name=$1 program=$2 fragment=$3 copy
  mutant=$((mutant + 1))
  copy="$WORK/mutant-$mutant.yml"
  sed -E "$program" "$CONFIG" >"$copy"
  if cmp -s "$CONFIG" "$copy"; then
    bad "$name" "the edit did not change the config"
    return
  fi
  has "$name" "$(config_problems "$copy")" "$fragment"
}
mutate "Dependabot's own default scope" 's/prefix: "ci\(ci\)"/prefix: "chore(deps)"/' "scope 'deps' is not in .omni-dev/scopes.yaml"
mutate "a type the guidelines do not list" 's/prefix: "ci\(ci\)"/prefix: "build(ci)"/' "type 'build' is not a type"
mutate "one scope in two that is not a scope" 's/prefix: "ci\(ci\)"/prefix: "ci(ci,deps)"/' "scope 'deps' is not in .omni-dev/scopes.yaml"
mutate "a prefix that is not type(scope)" 's/prefix: "ci\(ci\)"/prefix: "ci"/' "is not of the form type(scope)"
mutate "no prefix" '/^    commit-message:/d; /^      prefix:/d' "sets no commit-message prefix"
mutate "a long prefix, so a subject is over the limit" 's/prefix: "ci\(ci\)"/prefix: "ci(action,docs,ci)"/' "would be"
mutate "another directory" 's#^    directory: /$#    directory: /.github/workflows#' "not '/'"
mutate "another ecosystem" 's/package-ecosystem: github-actions/package-ecosystem: cargo/' "no github-actions entry"
mutate "the version" 's/^version: 2$/version: 1/' "not 'version: 2'"
mutate "the updates key" 's/^updates:$/other:/' "cannot read the updates"

summary
