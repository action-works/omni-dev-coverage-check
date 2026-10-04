#!/usr/bin/env bash
# What makes the jobs that exist to run the omni-dev install run it (#66).
#
# Usage: install-cache.sh prefix
#        install-cache.sh check <omni-dev-cache-hit>
#
# `actions/cache` restores ~/.cargo/bin/omni-dev on a hit and the platform and download
# steps are then skipped. The key holds the version and not the action's code, so a job
# that exists to run the install would pass on a cached binary after its first run for a
# version, whatever a pull request changed in the install. The jobs that exist for the
# install put a prefix in front of the key (`cache-prefix`), and check what the action
# says it did (the `omni-dev-cache-hit` output). Both are decided here, so the prefix and
# the check cannot disagree about which events must install.
#
# prefix   Prints the `cache-prefix` for $GITHUB_EVENT_NAME, and nothing else.
#            pull_request, push           install-<16 hex of $INSTALL_CODE_HASH>-
#            schedule, workflow_dispatch  run-<$GITHUB_RUN_ID>-<$GITHUB_RUN_ATTEMPT>-<$INSTALL_CACHE_LEG>-
#          $INSTALL_CODE_HASH is `hashFiles('action.yml', 'scripts/*.sh')`. Runs on
#          unchanged install code reuse the entry, so a change to it installs once and a
#          pull request does not write an entry per push. The weekly run and a manual run
#          are the ones that test the world rather than a change, so they install every
#          time, and a re-run (a new attempt) installs again.
#          $INSTALL_CACHE_LEG (optional, for a job with a matrix) names the leg, and only the
#          run-id prefix carries it. The legs of a job can resolve to the same key: a pinned
#          0.46.0 and `latest` when latest is 0.46.0, on the same runner. Sharing is right on
#          unchanged code (a hit is expected there), but with a prefix unique to the run one
#          leg's saved entry could be restored by another that started later, and `check`
#          would fail a leg that did nothing wrong. Letters, digits, dots, underscores and
#          hyphens, so it is safe in a key.
#
# check    Reads the `omni-dev-cache-hit` output of the first scenario of a job (a failed
#          scenario exposes no outputs, and the entry is saved in a post step, so the first
#          one sees the cache as the job found it). Exit status:
#            0  `false`: the install ran in this job.
#               `true` on a pull_request or push: the binary came from the entry an earlier
#               run saved for this action.yml and scripts/*.sh, which is the unchanged-code
#               case; the line says the install steps did not run here.
#            1  `true` on schedule or workflow_dispatch, whose prefix is unique to the
#               run, so a hit means the prefix never reached the action; or any other value.
#            2  no value: how a step that failed (and so exposed no output) arrives.
#          Every failure prints an `::error::` line on stderr.
#
# Why a hash of whole files and not of the install steps: the install code is action.yml
# and what it runs from scripts/, and hashing less would be a list kept in step by hand.
# tests/install-cache.test.sh fails when an install step runs a file the hash does not
# cover. A change elsewhere in action.yml reinstalls once, which costs seconds.
#
# stdout of `prefix` is the prefix alone, so a workflow can capture it; call it as
# `prefix="$(bash tests/install-cache.sh prefix)"`, not inside an `echo`, or a failure is
# lost under Actions' `bash -e`.
set -uo pipefail

err() {
  echo "::error::install-cache.sh: $*" >&2
}

# Events that run on no change of ours: they install every time instead of on a change.
installs_every_time() {
  case "${GITHUB_EVENT_NAME:-}" in
    schedule | workflow_dispatch) return 0 ;;
    *) return 1 ;;
  esac
}

prefix() {
  if [ -z "${GITHUB_EVENT_NAME:-}" ]; then
    err "GITHUB_EVENT_NAME is not set, so the event that decides the prefix is unknown"
    return 1
  fi
  if installs_every_time; then
    # A prefix that did not change with the run would hit the entry the last one saved.
    if [[ ! "${GITHUB_RUN_ID:-}" =~ ^[0-9]+$ || ! "${GITHUB_RUN_ATTEMPT:-}" =~ ^[0-9]+$ ]]; then
      err "a $GITHUB_EVENT_NAME run needs GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT to make its prefix unique; got '${GITHUB_RUN_ID:-}' and '${GITHUB_RUN_ATTEMPT:-}'"
      return 1
    fi
    local leg="${INSTALL_CACHE_LEG:-}"
    if [ -n "$leg" ] && [[ ! "$leg" =~ ^[0-9A-Za-z._-]+$ ]]; then
      err "INSTALL_CACHE_LEG may hold only letters, digits, dots, underscores and hyphens, as it goes into a cache key; got '$leg'"
      return 1
    fi
    echo "run-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${leg:+$leg-}"
    return 0
  fi
  # hashFiles gives an empty string when its globs match nothing. A constant prefix
  # would stop invalidating the cache and nothing would say so.
  if [[ ! "${INSTALL_CODE_HASH:-}" =~ ^[0-9a-f]{16,}$ ]]; then
    err "INSTALL_CODE_HASH must be a hex hash of the install code (hashFiles('action.yml', 'scripts/*.sh')), got '${INSTALL_CODE_HASH:-}'; do the globs match nothing?"
    return 1
  fi
  echo "install-${INSTALL_CODE_HASH:0:16}-"
}

check() {
  local hit="${1:-}"
  if [ -z "$hit" ]; then
    # Matching an empty value against everything would pass whatever the action did.
    err "check needs the action's omni-dev-cache-hit output; got none. Did the scenario fail, so that it exposed no outputs?"
    return 2
  fi
  case "$hit" in
    false)
      echo "ok   - omni-dev was installed in this job: no cache entry for this prefix, so the download and the extraction ran"
      ;;
    true)
      if [ -z "${GITHUB_EVENT_NAME:-}" ]; then
        err "GITHUB_EVENT_NAME is not set, so whether a cache hit is allowed is unknown"
        return 1
      fi
      if installs_every_time; then
        err "omni-dev was restored from the cache on a $GITHUB_EVENT_NAME run, whose cache-prefix is unique to the run, so nothing could have saved it; the prefix did not reach the action and the install did not run"
        return 1
      fi
      echo "ok   - omni-dev came from the cache, not from an install: an earlier run saved this entry for the same action.yml and scripts/*.sh, so the download and the extraction did not run in this job. A change to either installs again"
      ;;
    *)
      err "omni-dev-cache-hit is '$hit', expected true or false"
      return 1
      ;;
  esac
}

case "${1:-}" in
  prefix)
    [ "$#" -eq 1 ] || { echo "usage: install-cache.sh prefix" >&2; exit 2; }
    prefix
    ;;
  check)
    [ "$#" -le 2 ] || { echo "usage: install-cache.sh check <omni-dev-cache-hit>" >&2; exit 2; }
    check "${2:-}"
    ;;
  *)
    echo "usage: install-cache.sh prefix | check <omni-dev-cache-hit>" >&2
    exit 2
    ;;
esac
