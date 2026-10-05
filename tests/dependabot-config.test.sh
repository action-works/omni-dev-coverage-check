#!/usr/bin/env bash
# Tests for .github/dependabot.yml (#58). Plain bash, no framework:
#   tests/dependabot-config.test.sh
# Exits non-zero if any case fails.
#
# Dependabot opens a pull request for each action pin that is behind, and its commit message
# has to pass the required `Validate Commit Messages` (`omni-dev git commit message lint`, an
# error fails it). Its default, `chore(deps): ...`, does not: `deps` is not a scope of this
# project (.omni-dev/scopes.yaml). The check cannot be fixed on a bot's pull request afterwards
# (the commit is already written), so every entry of the config is held to what the lint needs:
# a prefix of the form `type(scope[,scope])` with every scope in scopes.yaml, no `include:` (with
# `include: scope` Dependabot writes `ci(ci)(deps): ...`, which the lint rejects as not
# `type(scope): description`), and, for the github-actions entry, a subject that fits for the
# longest action this repository uses with two-digit versions.
#
# This is stricter than the check on two things, on purpose: the type must be one of
# .omni-dev/commit-guidelines.md's seven (the lint's built-in list also takes build, perf and
# style) and the subject at most 72 characters (the lint's limit is 80, and Dependabot itself
# drops " from X to Y" from a subject over 72). Scopes are the same in both: the lint reads
# scopes.yaml. The lint was run on Dependabot's real message shape with omni-dev 0.45.0
# (`ci(ci)` on a change to action.yml passes, `chore(deps)` fails on its scope).
#
# The config is read with awk for the layout it has (an entry at 2 spaces, its keys at 4, the
# commit-message keys at 6) and a layout it cannot read is reported, as tests/merge-queue.test.sh
# does for the workflows. The real file is checked, and copies broken one way at a time must each
# be reported.

# The awk programs below are single-quoted on purpose: awk reads them, not the shell.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir

# The longest a subject may be: the project's own rule (a 73-character subject is over it).
MAX_SUBJECT=72

# updates_of <config>: one line per entry of `updates:`, `<ecosystem>|<directory>|<prefix>|<include>`
# (a field the entry lacks is empty), quotes taken off. Reports a file with no `updates:`.
updates_of() {
  awk '
    function flush() { if (eco != "") print eco "|" dir "|" prefix "|" include; eco = ""; dir = ""; prefix = ""; include = "" }
    function value(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]*(#.*)?$/, "", s); gsub(/^"|"$/, "", s); return s }
    /^updates:[ \t]*$/ { seen = 1; next }
    seen && /^[^ \t#]/ { flush(); seen = 0 }
    seen && /^  - package-ecosystem:/ { flush(); eco = value($0); n++; next }
    seen && /^    directory:/ { dir = value($0); next }
    seen && /^      prefix:/ { prefix = value($0); next }
    seen && /^      include:/ { include = value($0); next }
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

# subject_problem <prefix> <name>: says so if the subject Dependabot writes for <name>,
# `<prefix>: bump <name> from 99 to 100`, is over the limit.
subject_problem() {
  local subject="$1: bump $2 from 99 to 100"
  [ "${#subject}" -le "$MAX_SUBJECT" ] || echo "the subject for $2 would be ${#subject} characters ($subject), over $MAX_SUBJECT"
}

# prefix_problems <ecosystem> <prefix> <include>: the problems of one entry's commit message.
prefix_problems() {
  local eco=$1 prefix=$2 include=$3 type scopes scope
  if [ -z "$prefix" ]; then
    echo "the $eco entry sets no commit-message prefix: Dependabot's default scope, deps, fails the lint"
    return
  fi
  if ! [[ "$prefix" =~ ^([a-z]+)\(([a-z,]+)\)$ ]]; then
    echo "the $eco prefix '$prefix' is not of the form type(scope)"
    return
  fi
  type="${BASH_REMATCH[1]}"
  scopes="${BASH_REMATCH[2]}"
  grep -Fq "| \`$type\`" "$ROOT/.omni-dev/commit-guidelines.md" || echo "the $eco prefix's type '$type' is not a type of .omni-dev/commit-guidelines.md"
  for scope in ${scopes//,/ }; do
    grep -Fxq "  - name: \"$scope\"" "$ROOT/.omni-dev/scopes.yaml" || echo "the $eco prefix's scope '$scope' is not in .omni-dev/scopes.yaml"
  done
  [ -z "$include" ] || echo "the $eco entry sets include: $include, which Dependabot writes into the subject as a second scope after the prefix: the lint rejects it"
}

# config_problems <config>: one line per problem, nothing if there is none.
config_problems() {
  local cfg=$1 err="$WORK/reader.err" rows row eco dir prefix include name names measured=0
  grep -Fxq 'version: 2' "$cfg" || echo "the config is not 'version: 2'"
  if ! rows="$(updates_of "$cfg" 2>"$err")"; then
    echo "cannot read the updates: $(<"$err")"
    return
  fi
  # Every entry commits, so every entry's prefix is held to the lint.
  while IFS= read -r row; do
    IFS='|' read -r eco dir prefix include <<<"$row"
    prefix_problems "$eco" "$prefix" "$include"
    [ "$eco" = github-actions ] || continue
    [ "$dir" = / ] || echo "a github-actions entry reads directory '$dir', not '/': action.yml and the workflows are at the root"
    # The subject for the longest action, only where the prefix is one that can be measured.
    [ -n "$prefix" ] || continue
    names="$(uses_names)"
    if [ -z "$names" ]; then
      echo "no action found to measure a subject for"
      continue
    fi
    while IFS= read -r name; do
      subject_problem "$prefix" "$name"
      measured=$((measured + 1))
    done <<<"$names"
  done <<<"$rows"
  grep -q '^github-actions|' <<<"$rows" || echo "no github-actions entry: the pins would not be kept current"
  if grep -q '^github-actions|' <<<"$rows" && [ "$measured" -eq 0 ]; then
    echo "no subject was measured for the github-actions entry"
  fi
}

CONFIG="$ROOT/.github/dependabot.yml"
pass "the config exists" test -f "$CONFIG"
eq "the real config: no problem" "" "$(config_problems "$CONFIG")"

# The readers on the real data: the entry, and what is measured.
has "the real config: a github-actions entry, at the root, with the prefix and no include" "$(updates_of "$CONFIG")" "github-actions|/|ci(ci)|"
pass "the actions measured include the longest one in use" grep -Fxq 'marocchino/sticky-pull-request-comment' <(uses_names)
lacks "a local action is not measured" "$(uses_names)" "./"
# Every action file is read: one that is only in a workflow is measured too.
pass "an action only a workflow uses is measured" grep -Fxq 'codecov/codecov-action' <(uses_names)

# The limit, exactly: 25 characters are `: bump a/b from 99 to 100`, so a prefix of 47 gives a
# subject of 72 and one of 48 gives 73.
pad() { printf 'x%.0s' $(seq 1 "$1"); }
eq "a subject of exactly 72 characters is within the limit" "" "$(subject_problem "$(pad 47)" a/b)"
has "a subject of 73 characters is over it" "$(subject_problem "$(pad 48)" a/b)" "would be 73 characters"

# With nothing to measure the subject for, the check says so and does not pass on an empty list
# (a loop fed an empty here-string runs once, with an empty name).
mkdir -p "$WORK/bare"
cp -R "$ROOT/.omni-dev" "$WORK/bare/.omni-dev"
has "no action file to read: reported, not passed" "$(ROOT="$WORK/bare" config_problems "$CONFIG" 2>/dev/null)" "no action found to measure a subject for"

# Each way to break it, on a copy of the real file, must be reported. Every edit is checked to
# have changed the copy: a no-op would pass for the wrong reason. The edit is an awk program
# over the file, and may read NEW from the environment.
mutant=0
# mutate <name> <awk program> <fragment the problems must hold>
mutate() {
  local name=$1 program=$2 fragment=$3 copy
  mutant=$((mutant + 1))
  copy="$WORK/mutant-$mutant.yml"
  awk "$program" "$CONFIG" >"$copy"
  if cmp -s "$CONFIG" "$copy"; then
    bad "$name" "the edit did not change the config"
    return
  fi
  has "$name" "$(config_problems "$copy")" "$fragment"
}
SWAP='{ if ($0 ~ /^      prefix:/) print "      prefix: \"" ENVIRON["NEW"] "\""; else print }'
NEW='chore(deps)' mutate "Dependabot's own default scope" "$SWAP" "scope 'deps' is not in .omni-dev/scopes.yaml"
NEW='build(ci)' mutate "a type the guidelines do not list" "$SWAP" "type 'build' is not a type"
NEW='ci(ci,deps)' mutate "one scope in two that is not a scope" "$SWAP" "scope 'deps' is not in .omni-dev/scopes.yaml"
NEW='ci' mutate "a prefix that is not type(scope)" "$SWAP" "is not of the form type(scope)"
NEW='ci (ci)' mutate "a space in the prefix" "$SWAP" "is not of the form type(scope)"
NEW='CI(ci)' mutate "an upper-case type" "$SWAP" "is not of the form type(scope)"
NEW='ci(ci):' mutate "a prefix that already has its colon" "$SWAP" "is not of the form type(scope)"
NEW='ci(action,docs,ci)' mutate "a long prefix, so a subject is over the limit" "$SWAP" "would be"
mutate "no prefix" '!/^    commit-message:/ && !/^      prefix:/' "sets no commit-message prefix"
mutate "include: scope, which writes a second scope into the subject" '{ print } /^      prefix:/ { print "      include: scope" }' "sets include: scope"
mutate "another directory" '{ if ($0 ~ /^    directory:/) print "    directory: /.github/workflows"; else print }' "not '/'"
mutate "another ecosystem" '{ sub(/package-ecosystem: github-actions/, "package-ecosystem: cargo"); print }' "no github-actions entry"
mutate "the version" '{ sub(/^version: 2$/, "version: 1"); print }' "not 'version: 2'"
mutate "the updates key" '{ sub(/^updates:$/, "other:"); print }' "cannot read the updates"

# Every entry commits, so a second one is held to the lint as well (and adding one needs no edit
# here): a cargo entry with no prefix would write `chore(deps)`, and a second github-actions one
# with a bad prefix likewise.
mutate_append() { # <name> <yaml lines appended> <fragment>
  local name=$1 text=$2 fragment=$3 copy
  mutant=$((mutant + 1))
  copy="$WORK/mutant-$mutant.yml"
  { cat "$CONFIG"; printf '%s\n' "$text"; } >"$copy"
  has "$name" "$(config_problems "$copy")" "$fragment"
}
mutate_append "a second entry with no prefix" '  - package-ecosystem: cargo
    directory: /
    schedule:
      interval: weekly' "the cargo entry sets no commit-message prefix"
mutate_append "a second github-actions entry with a bad prefix" '  - package-ecosystem: github-actions
    directory: /sub
    commit-message:
      prefix: "chore(deps)"' "scope 'deps' is not in .omni-dev/scopes.yaml"
eq "a second entry with a good prefix is not a problem" "" "$(
  copy="$WORK/second-good.yml"
  { cat "$CONFIG"; printf '%s\n' '  - package-ecosystem: cargo' '    directory: /' '    commit-message:' '      prefix: "ci(action)"'; } >"$copy"
  config_problems "$copy"
)"

summary
