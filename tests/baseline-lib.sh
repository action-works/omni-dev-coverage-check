#!/usr/bin/env bash
# shellcheck disable=SC2034 # `status` is the sourcing step's: set here, read there
# Helpers for holding the baseline lookup to what it should have found, shared by
# pr-paths.yml and e2e-sharded.yml. Source it in a checking step that has `status`,
# `check` and `assert` (the second workflow gets them from tests/assert-lib.sh, the first
# defines them inline): a failed check sets `status=1` in the caller, which ends its step
# with `exit "$status"`. tests/baseline-lib.test.sh tests it.
#
# A pull request's baseline is the merge-base's own, or the nearest first-parent ancestor's
# that has one (`baseline-ancestor-depth`). Every record of a published baseline names the
# commit it was published for in its `TN:` line, which is how a downloaded baseline says
# which one it is, and the comment ends with a note when it is not the merge-base's.
#
# `expected_baseline` can be set before sourcing (the tests do) to point at another script.

expected_baseline="${expected_baseline:-tests/expected-baseline.sh}"

# How many first-parent commits before <start> a commit is (0: it is <start>). Prints
# nothing if it is not on that line.
distance_of() { # <start> <sha>
  git rev-list --first-parent "$1" | grep -nx "$2" | head -n1 | cut -d: -f1 |
    awk '$1 != "" { print $1 - 1 }'
}

# The commit(s) a baseline was published for, one per line: its `TN:` lines, once each.
tn_of() { # <lcov>
  sed -n 's/^TN://p' "$1" | sort -u
}

# The sentence the comment ends with when the baseline is an ancestor's, from `, ` on.
note_for() { # <n>
  if [ "$1" -eq 1 ]; then
    echo ", 1 commit before the merge-base, which has none."
  else
    echo ", $1 commits before the merge-base, which has none."
  fi
}

# What a comment says about its baseline, given the baseline's `TN:` commit and the commit
# the comparison started from: nothing if it is that commit's own, else which commit and how
# far back. The wording is the diff step's of action.yml.
check_note() { # <label> <start> <tn> <comment file>
  local n
  n="$(distance_of "$2" "$3")"
  if [ -z "$n" ]; then
    echo "::error::$1: the baseline's commit ${3:0:7} is not on the first-parent line of ${2:0:7}"
    status=1
  elif [ "$n" -eq 0 ]; then
    assert "$1: the baseline is the start's own, so the comment makes no claim about it" \
      test "$(grep -c 'before the merge-base, which has none' "$4")" = 0
  else
    assert "$1: the comment says the baseline is for ${3:0:7}" grep -qF "[\`${3:0:7}\`]" "$4"
    assert "$1: the comment says how far back ($n)" grep -qF "$(note_for "$n")" "$4"
  fi
}

# Holds what a scenario found to what tests/expected-baseline.sh says it should have: a hit
# must be the commit the API names (the nearest with a live baseline), a miss must be a miss,
# and `either` (a nearer run still in progress) may be anything. A scenario that found a
# baseline has downloaded it to <baseline lcov>.
held_to_the_api() { # <label> <workflow> <artifact> <start> <baseline lcov>
  local kind sha distance observed=miss tn=
  read -r kind sha distance <<<"$(bash "$expected_baseline" "$2" "$3" "$4")"
  if [ -s "$5" ]; then
    observed=hit
    tn="$(tn_of "$5")"
  fi
  echo "::notice::$1: lookup from ${4:0:7}: expected $kind${sha:+ ${sha:0:7}, $distance back}, observed $observed${tn:+ ${tn:0:7}}"
  case "$kind:$observed" in
    hit:hit) check "$1: the baseline found is the one for ${sha:0:7}, the nearest" "$sha" "$tn" ;;
    miss:miss | either:*) echo "ok   - $1: the lookup found what the API says it should" ;;
    *)
      echo "::error::$1: the lookup found a baseline: $observed; the API says: ${kind:-nothing (did tests/expected-baseline.sh fail?)}"
      status=1
      ;;
  esac
}
