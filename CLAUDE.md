# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitHub Action that runs code-coverage analysis and posts a diff/patch-coverage pull-request comment using the [omni-dev](https://github.com/rust-works/omni-dev) CLI tool. It is the coverage counterpart to [action-works/omni-dev-commit-check](https://github.com/action-works/omni-dev-commit-check) and reuses that action's omni-dev install + cache pattern verbatim.

## Repository Structure

- `action.yml` - The composite GitHub Action definition (the core of this project)
- `README.md` - User documentation with examples and input/output reference
- `scripts/combine-shards.sh` - Checks and joins per-shard lcov files for the `shard-reports` input
- `scripts/omni-dev-asset.sh` - Maps a runner's OS and architecture to the omni-dev release asset to download (`tests/omni-dev-asset.test.sh` tests it; `test.yml` runs that)
- `scripts/find-baseline.sh` - Decides which run's baseline artifact a pull request downloads: the merge-base's, else the nearest first-parent ancestor's (`tests/find-baseline.test.sh` tests it against a stub `curl` and throwaway git repositories; `test.yml` runs that)
- `tests/baseline-steps.test.sh` - Reads the lookup, download and diff steps out of `action.yml` and checks the wiring (the variables the script requires, the run id handed to the download, the comment's ancestor note) (`test.yml` runs that)
- `tests/platform-step.test.sh` - Runs the "Determine platform and download URL" and "Fail if binary not available" scripts read out of `action.yml` against a stub `curl`, with the variables the steps' `env:` blocks fill set directly (`test.yml` runs that)
- `tests/guard-step.test.sh` - Runs the "Check omni-dev supports the flags this run uses" script read out of `action.yml` against a stub `omni-dev` that answers the probe as clap does, and against the real answers in `tests/fixtures/omni-dev-probe/` (`test.yml` runs that)
- `tests/resolve-version-step.test.sh` - Runs the "Resolve omni-dev version" script read out of `action.yml` against a stub `curl` that replays scripted responses (the API's, then the redirect's) and a stub `sleep` (`test.yml` runs that)
- `tests/input-steps.test.sh` - Runs the steps that read a caller's input (the test, setup and extra commands, the report, merge-base, recompute, diff and the gates) read out of `action.yml` against stub `cargo`, `git`, `omni-dev` and `sudo`, with hostile values that must stay data (`test.yml` runs that)
- `tests/check-run-expressions.sh` - Fails when a `run:` body of `action.yml` holds a `${{ }}` expression (`tests/check-run-expressions.test.sh` tests it; `test.yml` runs both)
- `tests/combine-shards.test.sh` - Plain-bash tests for that script (`.github/workflows/test.yml` runs them)
- `tests/test-lib.sh` - The helpers every `tests/*.test.sh` sources: `ok`, `bad`, `eq`, `has`, `lacks`, `pass`, `fail` and the closing `summary` (`tests/test-lib.test.sh` tests it, including how a failed case fails; `test.yml` runs that)
- `tests/step-lib.sh` - `step_run`, `step_block` and `input_block`: the one reader of `action.yml`'s steps and inputs, for the three step tests; it refuses a layout it cannot read (`tests/step-lib.test.sh` tests it; `test.yml` runs that)
- `.omni-dev/` - Project guidelines for commits and PRs
- `.github/workflows/commit-check.yml` - Dogfoods the commit-check action on this repo
- `.github/workflows/integration.yml` - Runs the action itself (`uses: ./`) in thin mode against fixture lcov (on x86_64 Linux and, from omni-dev 0.46.0, on ARM64 Linux, where `arm64-release-without-asset` is the control for the ARM64 legs), and in fat mode against `tests/fixtures/fat-crate/`; the `output-flag` job checks the omni-dev floor a pull request needs; the `ignore-filename-regex` job checks the filter on the thin-mode line gate and `ignore-filename-regex-flag` the omni-dev floor for it; the `deprecation-control` job logs an omni-dev deprecation warning on purpose, and asks `latest` about a flag that cannot exist, as the guard's probe does; the `latest-redirect` job resolves `version: latest` with a token the API refuses, so the redirect has to answer; a last job asserts the failure messages the scenarios logged and that no other job logged a deprecation warning
- `tests/job-log.sh` - Prints the log of one job of the current run, read through the Actions API; `job-errors.sh` and `job-deprecations.sh` pick their lines from it (`tests/job-errors.test.sh` tests all three against a fake `gh`; `test.yml` runs that)
- `tests/job-errors.sh` - Prints the `##[error]` messages one job of the current run logged
- `tests/job-deprecations.sh` - Prints the `warning: ... deprecated` lines one job of the current run logged
- `tests/fixtures/fat-crate/` - Dependency-free crate the fat-mode integration job copies to the workspace root (never run in place)
- `tests/move-outputs.sh` - Moves one scenario's outputs aside between scenarios (shared by the fat-mode and PR-path jobs)
- `tests/llvm-tool-shim.sh` - Pass-through for `llvm-cov`/`llvm-profdata` that logs each `llvm-profdata merge`; the fat-mode job installs it to assert the profile is merged once (see "One profile merge"; `tests/llvm-tool-shim.test.sh` tests it, with stub tools; `test.yml` runs that)
- `.github/workflows/pr-paths.yml` - Runs the action down the paths only a pull request or a push to `main` takes: the sticky comment, baseline publish and hit, the ancestor fallback, the merge-base worktree recompute, and `ignore-filename-regex` reaching the comment and the patch gate
- `tests/write-pr-fixtures.sh` - Writes the sharded lcov fixtures and the locally committed `patch-fixture.txt` that `pr-paths.yml` runs on (`extra` adds a second patched file for P5 and P6)
- `tests/read-sticky-comment.sh` - Reads (and optionally deletes) the sticky comment for a header through the API
- `tests/fixtures/delta-crate/` - Base and head versions of a crate, committed in a job to give the merge-base recompute a base commit
- `.github/workflows/e2e-sharded.yml` - A real sharded run: a shard matrix (`cargo llvm-cov nextest --partition`), the artifact hand-off, and an aggregation job running the action, with the pull-request / `main` loop on top
- `tests/prepare-shard-crate.sh` - Copies the shard fixture crate to `sharded-crate/`; with `--commit`, also commits it locally (`tests/prepare-shard-crate.test.sh` tests it; `test.yml` runs that)
- `tests/assert-lib.sh` - Assertion helpers the `e2e-sharded.yml` checking steps source (`tests/assert-lib.test.sh` tests them; `test.yml` runs that)
- `tests/expected-baseline.sh` - What the baseline lookup should find for a commit, read from the Actions API through `gh` (`tests/expected-baseline.test.sh` tests it against a stub `gh`; `test.yml` runs that)
- `tests/baseline-lib.sh` - Checks of a baseline's `TN:` commit, the comment's ancestor note and the lookup against `expected-baseline.sh`, sourced by `pr-paths.yml` and `e2e-sharded.yml` (`tests/baseline-lib.test.sh` tests it, including against the real diff step; `test.yml` runs that)
- `tests/check-deprecated-flags.sh` - Fails when `action.yml` or `scripts/*.sh` passes omni-dev a deprecated flag (`tests/check-deprecated-flags.test.sh` tests it; `test.yml` runs both)
- `tests/assert-omni-dev-version.sh` - Fails unless the `omni-dev` on PATH is exactly the pinned version; the jobs that assert a scenario's outcome, in `integration.yml`, `pr-paths.yml` and `e2e-sharded.yml`, end on it (`tests/assert-omni-dev-version.test.sh` tests it; `test.yml` runs that)
- `tests/fixtures/shard-crate/` - Dependency-free crate the shard jobs measure (copied to `sharded-crate/`, never run in place)
- `tests/fixtures/omni-dev-probe/` - What the real releases either side of each guard floor (and 0.28.0, which has no `coverage`) answered to the guard's probe, one `<version>/<flag>.txt` each: `exit=<status>`, then the output (`tests/guard-step.test.sh` replays them)
- `.github/pull_request_template.md` - PR template

## How It Works

The action is a composite action with two phases:

1. **Install omni-dev** (carried over from omni-dev-commit-check): resolve the
   version (`latest` → newest release tag, or a pinned value), restore the
   `~/.cargo/bin/omni-dev` cache (`actions/cache@v4`), and on a miss download a
   pre-built release binary, falling back to `cargo install omni-dev`.
2. **Coverage pipeline**:
   - **Fat mode (default, `run-coverage: true`)**: set up `llvm-tools-preview` +
     `cargo-llvm-cov`, run `cargo test` under instrumentation (sourcing
     `cargo llvm-cov show-env --sh` per step so every cargo step shares one set
     of instrumented dependency artifacts), then emit the per-line `report` lcov
     (the first report: it merges the raw profiles, once), remove the raw profiles,
     and emit `codecov.json` and a `--summary-only` summary, which read that
     merged profile.
   - **Thin mode (`run-coverage: false`)**: skip cargo-llvm-cov entirely; the
     caller supplies the per-line lcov via the `report` input — or, for a run
     sharded across jobs, via `shard-reports`, which `scripts/combine-shards.sh`
     checks and joins into `report` so every later step still reads one file.
   - On pull requests: compute the `origin/main`..`HEAD` merge-base, find the
     `coverage-baseline` artifact for that commit or, failing that, the nearest
     first-parent ancestor's (`scripts/find-baseline.sh`), download it by run id, and
     when none is in reach recompute it at the merge-base in a git worktree (fat
     mode). Render the comment with
     `omni-dev coverage diff` and post it via
     `marocchino/sticky-pull-request-comment`.
   - On pushes to `main`: publish this run's lcov as the `coverage-baseline`
     artifact.
   - **Gates run last** so the summary and PR comment still post when a gate
     fails: `--fail-under-patch` (patch coverage) then the overall line gate —
     `cargo llvm-cov report --fail-under-lines` in fat mode, `omni-dev coverage
     diff --fail-under-lines` in thin mode (which has no profile data).

## Key Technical Details

- **Binary source**: the action runs the *installed* `omni-dev` (on PATH from
  `~/.cargo/bin`), not a `target/debug/omni-dev` built by the coverage run — that
  is the whole point of the install/cache phase, and it is what lets thin mode
  work without any cargo build.
- **Baseline is pinned to the merge-base's first-parent line**, not "latest main", so
  per-file deltas are attributable to the PR alone, give or take the commits between
  the merge-base and the baseline when it is an ancestor's (the next bullet).
- **Baseline lookup** (#5): `scripts/find-baseline.sh` decides which run's artifact to
  download, and `dawidd6/action-download-artifact` downloads it by `run_id`. `dawidd6`'s
  `commit:` lookup could not do the job: it takes the newest successful run of ONE
  `head_sha` and looks for the artifact in that run only (a `merge_group` run with no
  artifact hides the `push` run that has it), it cannot walk ancestors (a step cannot
  loop), and a workflow the API does not know yet throws whatever `if_no_artifact_found`
  says. `check_artifacts`/`search_artifacts` would fix only the first, and neither checks
  `expired`. Rules, so they are not re-derived:
  - Candidates are the merge-base, then up to `baseline-ancestor-depth` of its
    first-parent ancestors, nearest first (default `10`; `0` is the exact lookup). A
    commit has a baseline if a successful run of `baseline-workflow` for it holds an
    unexpired artifact of that name. ANY such run counts, not the newest. Only first
    parents: on `main` they are the merged pull requests, each of which published one,
    where a second parent is a pull request's own branch.
  - A run from a fork is skipped (`head_repository.full_name` must be this repository),
    as `dawidd6`'s `allow_forks: false` did. A fork's pull request can carry any head SHA
    and upload any artifact name, so trusting it would let it write the baseline.
  - No `event` or `branch` filter: the artifact is the precise filter, and a `push`
    filter would break a caller that publishes from a schedule or a manual run. Runs not
    yet `success` are not used even if they have uploaded; the walk is what covers the
    race (the `push` run unfinished, so the next ancestor is used instead of a rebuild).
  - A 404 for the workflow is a warned miss that ends the walk: the API knows a workflow
    only once its file is on the default branch, and every candidate would 404 alike.
    Transient statuses (no response, 429, 5xx) are tried three times. After that the FIRST
    request failing is an error with the status and the API's message, as before: a
    permission or an outage must not read as "no baseline", or every pull request would
    quietly pay for a rebuild. A failure on a later request is a warned miss: the first one
    worked, so the credentials do, the baseline is optional, and the walk makes many more
    requests than the old single lookup, so one blip on the eleventh must not fail a pull
    request. A runner with no `jq`, `curl` or `git` gets a warned miss that names it: without
    `jq` the names encode to nothing and the request is a 404 that would read as "no such
    workflow".
  - **On by default**, decided in #5: the issue proposed the walk as the behaviour and
    "at least an option" as the floor. It changes only a pull request whose merge-base
    has no baseline. To make exactness the default, change the default in `action.yml`
    (`baseline-steps.test.sh` pins `'10'`; `expected-baseline.sh` reads it from there).
  - omni-dev renders "Comparing merge-base -> head" and "vs main" and only displays
    `--base-sha`, so when the baseline is an ancestor's the diff step appends one line
    naming its commit and distance. Not when there is no downloaded file, and not when the
    recompute built it: the lookup can have found an ancestor's whose download left no file
    under this report's name (it expired in between, or the report was renamed), and the
    recompute's baseline is the merge-base's own, so it sets `recomputed` and the diff step
    reads that. The patch is unaffected: `--base-ref` stays the merge-base.
    `tests/baseline-lib.sh` pins the wording against the real step.
  - Each commit tried costs at least one API request, plus one per successful run it
    has; a full miss spends `depth + 1`. `GITHUB_TOKEN` has 1,000 an hour per
    repository, which is why `integration.yml` passes `baseline-ancestor-depth: 0` (up to
    16 lookups per pull-request run, and none finds anything), and why the depth is a bound.
  - The recompute stays the last resort and runs only when nothing is in reach, so the
    `recompute` job of `pr-paths.yml` turns the walk off: its synthetic base has none.
- **`worktree-system-deps`** generalizes the one omni-dev-specific wrinkle from
  the original inline job (installing `libasound2-dev` before building old
  history); it installs nothing unless set.
- **`setup-commands` / `extra-test-commands`** let a caller whose coverage corpus
  isn't a single `cargo test` run still use fat mode (e.g. omni-voice: download a
  Whisper model, then run `--ignored` model-gated suites). `setup-commands` runs
  pre-test with `LLVM_PROFILE_FILE=/dev/null` (reuses the instrumented build,
  contributes no coverage); `extra-test-commands` runs post-test and DOES
  contribute. Both are skipped in the worktree recompute, so the merge-base stays
  buildable at old fork points and only `test-args` defines that baseline. Both are
  shell and are run with `eval "$VAR"` in the step's own shell (see the #39 bullet).
- **No expression in any `run:` body (#39)**: the runner replaces every `${{ }}` in a script
  with its value before the shell parses it, so a value that held shell syntax ran as shell.
  Every value a script reads now comes through the step's `env:` and is read as `"$VAR"`,
  `runner.*`, `github.action_path` and step outputs included, so the rule has no exceptions to
  keep a list of. `tests/check-run-expressions.sh` enforces it (a line scan: it reads every
  `run:` body, comments and messages too, because the runner evaluates those; `if:`, `with:`
  and `env:` are where expressions belong). Rules:
  - A new step that needs a value adds it to `env:`. Name it for the input, upper-cased
    (`REPORT`, `STRIP_PREFIX`); `BASE_SHA` is the merge-base commit, `BASE_REF` the `base-ref`
    input. Not `RUNNER_*` or `GITHUB_*`: the runner reserves those names for setting. The
    built-ins are mapped explicitly rather than read (`OS`, `ARCH`, `ACTION_PATH`) so a step's
    inputs are in one block, and the tests pin each mapping.
  - The check's `ALLOWED` list (`step name :: expression :: reason`, separator ` :: ` because an
    expression often holds `||`) is empty and only shrinks: an entry that matches nothing fails
    it. Do not add one for a value a caller supplies.
  - `setup-commands` and `extra-test-commands` are shell by design, so they are not allowlisted
    but run as `eval "$commands"` in the step's own shell: the same `-e -o pipefail`, the
    exported instrumentation env, one shell for every line. Rejected: `bash file` or `bash -c`
    (a child shell has neither `-e` nor `pipefail` unless re-added, and loses non-exported
    state). `eval` does not make these two inputs safe (a value in them still runs as shell, as
    before); it takes the runner's substitution out of the script text, and the README says never
    to wire an untrusted value into either.
  - `test-args` and `worktree-system-deps` are split on whitespace into an array with
    `set -f; words=($VAR); set +f`: no quote removal, expansion or globbing, and no `|| true`
    (an earlier `read -r -d '' -a` needed one, which also hid real read failures). A value that
    holds a quote, a backslash, `$` or a backtick is REFUSED with an `::error::` rather than
    split: both inputs used to be shell-parsed, and splitting `--skip "slow test"` into
    `--skip`, `"slow` and `test"` ran zero tests and still exited 0. `worktree-system-deps` also
    refuses a word that starts with `-`, since `apt-get` reads one as an option (`-o
    DPkg::Pre-Invoke::=...` runs a command as root). This is a breaking change for a caller who
    wrote shell quoting or `$VAR` in `test-args`; the README says how to upgrade. A newline in
    either now separates words, where it used to end the command. Rejected:
    `eval "cargo test $TEST_ARGS"` (the hole itself) and a quote-aware splitter (`xargs` differs
    between GNU and BSD, and bash 3.2 has no `mapfile`).
  - The variables are generic names, and `cargo`, a dependency's build scripts and the caller's
    commands inherit a step's environment, so the steps that run them drop the action's
    variables first: `unset TEST_ARGS` and the command variables (copied into `commands`), `env
    -u VERSION cargo install`, and `unset REPORT WORKTREE_SYSTEM_DEPS TEST_ARGS BASE_SHA` before
    the merge-base's `cargo llvm-cov`. `tests/input-steps.test.sh` asserts it.
  - The step tests set the variables and assert that each step's `env:` block fills them from
    the right place, and that the script holds no expression: setting variables alone would
    pass if `env:` were wired wrong. `tests/input-steps.test.sh` runs every other step that
    reads an input against stub `cargo`, `git`, `omni-dev` and `sudo` and asserts the
    arguments, with a canary command in each hostile value that must never run. A mutation run
    (remove each guard, unset, `set -f` or quote in a copy of `action.yml`) is how its coverage
    was checked.
  - Not covered by a unit test: the pull-request paths on a real runner (`pr-paths.yml`,
    `e2e-sharded.yml`, `integration.yml`'s fat-mode job) and the download step (it writes to
    `/tmp`; `platform-step.test.sh` covers what picks its URL).
  - Left alone, found in review: the pinned `version` is not validated, so a value holding a
    newline or `/..` can write extra lines to `$GITHUB_OUTPUT` or steer the download URL. That
    predates #39 and is not an expression-evaluation hole; it is a follow-up, not done here.
- **Shard join**: `cargo llvm-cov` writes no newline after its final `end_of_record`,
  so a bare `cat` of shards glues records and a consumer can silently drop a file.
  `combine-shards.sh` always puts a newline between shards; keep that if you touch it.
- **One profile merge (decided in #4)**: every `cargo llvm-cov report` runs
  `llvm-profdata merge` over all the raw profiles first, so a run that leaves thousands
  of them (tests that spawn processes) paid for the merge once per report: four times
  (codecov, lcov, summary, line gate). The lcov step is now the first report and the
  "Remove merged raw coverage profiles" step after it runs `cargo llvm-cov clean
  --profraw-only`; a report that finds no `*.profraw` but a `.profdata` skips the merge
  (cargo-llvm-cov 0.6.9), so codecov, summary and the gate read the merged profile.
  Outputs are byte-identical. Rules:
  - The lcov step stays ahead of every other `cargo llvm-cov report` step. One placed
    before it merges again and nothing fails but the time, which is why CI counts merges.
  - The removal step is not `continue-on-error`. Its failure costs only speed if it
    removes nothing, but one that stops halfway leaves some raw profiles, and the next
    report merges only those over the full profile: a fraction of the coverage, no error.
  - The profile is kept, only the raw profiles go (`--profraw-only` keeps the
    `.profdata`). The first fat-mode step is `clean --workspace`, which removes the
    `.profdata`, so a run on a reused runner cannot report an earlier run's profile.
    Keep that step ahead of the test run.
  - Do not call `llvm-profdata`/`llvm-cov` directly to cut further: cargo-llvm-cov owns
    object-file discovery, the default ignore regex, the demangler and the codecov JSON
    conversion. There is also no merge-only command (`report --no-report` is rejected).
  - The gate stays its own `report --summary-only --fail-under-lines` call rather than
    folded into the summary: folding needs a failure deferred across steps to keep
    "gates run last", and after the merge the gate costs one `llvm-cov` pass.
  - The fat-mode integration job puts pass-through shims (`tests/llvm-tool-shim.sh`)
    on `LLVM_COV` and `LLVM_PROFDATA` (both, because setting one makes cargo-llvm-cov
    warn). Each merge appends a line to `llvm-profdata-merges.txt`, which
    `move-outputs.sh` files per scenario. F1, F2 and F3 expect 1 (the old order gives
    4, 4 and 3) and F4, which stops before any report, expects 0, so the 1s are counts.
    A cargo-llvm-cov that stopped skipping the merge, or whose `--profraw-only` stopped
    working, shows up as a different count or as reports that fail. The action installs
    the newest cargo-llvm-cov, and this was exercised on 0.9.1 only. F1 also checks that
    `codecov.json`, the one output that used to merge for itself, agrees with the lcov
    on every fixture function, since naming `src/lib.rs` would hold for an empty profile.
  - Measured on a synthetic corpus only (1,503 raw profiles): 4 merges to 1, each report
    1.6-1.9 s to 0.5-0.9 s. The consumer's saving (about 6 of 8 minutes at succinctly,
    where the four formats each took 123-128 s) is inferred from those near-equal times,
    not measured.
- **Pre-built asset is chosen by OS *and* architecture**: `scripts/omni-dev-asset.sh`
  maps `runner.os` + `runner.arch` to the release asset, and exits 1 for a pair with no
  asset rather than returning the nearest one. Linux used to map to the x86_64 build
  whatever the architecture, so an ARM64 runner downloaded a binary it could not run and
  failed at the version check, far from the step that chose it (#19). Windows ARM64 still
  takes the x86_64 asset (Windows on ARM emulates it); a 32-bit Windows gets none. The
  platform step turns "no asset for this pair" and "the release has no such file" into
  one `reason` output, which "Fail if binary not available" prints as the error. Keep it
  one message: `integration.yml` asserts its text, and `tests/platform-step.test.sh` reads
  both steps' scripts out of `action.yml` to pin the wiring. Only an HTTP 404 means the
  release lacks the asset; any other status (a refused connection is `000`) says the lookup
  failed and to re-run, so a network blip is not reported as a missing asset. curl prints `000`
  but also exits non-zero for a refused connection, and `shell: bash` runs with `-e`, so the
  lookup is `curl … || true`; without it the step ends with curl's bare exit code before it can
  say anything. The stub `curl` in `tests/platform-step.test.sh` exits 7 for `000` for the
  same reason: a stub that exits 0 lets the `000` cases pass without the step surviving
  them. A new release
  asset is one more case in the script and in `tests/omni-dev-asset.test.sh`.
  `arm64-release-without-asset` runs on a real ARM64 runner against `OLD_OMNI_DEV` (which
  never gets an ARM64 asset), with 5b as its control. The install that succeeds is the
  ARM64 legs of `thin-mode` (#20): they run the thin-mode scenarios on `ubuntu-24.04-arm`
  against `0.46.0`, the first release that publishes `omni-dev-linux-arm64.tar.gz`
  (rust-works/omni-dev#2148), and against `latest`, so the asset's name, the archive layout
  `tar -xzf … -C /tmp; mv /tmp/omni-dev` relies on (`omni-dev` at the archive root, beside
  `omni-dev-mcp`, `LICENSE` and `README.md`) and the binary itself are held to a real
  release, when the install runs (see the cache rule below). Rules:
  - The `0.46.0` leg is the floor for the ARM64 pre-built install and stays put, as
    `0.45.0` does for the gate; unlike `OLD_OMNI_DEV` it does not wait on anything. The
    matrix cannot read `env`, so the version is a literal and `failure-messages` repeats
    it (with the leg's job name, `Thin mode (omni-dev 0.46.0, ARM64)`: the x86_64 legs
    keep the names they had, so no lookup or required check moved).
  - The legs run on `ubuntu-24.04-arm`, not an older ARM image: omni-dev's Linux binaries,
    the x86_64 ones too, need glibc 2.39 (the highest `GLIBC_` version in each binary's
    version-needs table, read from the 0.45.0 and 0.46.0 releases), Ubuntu 24.04's, so an
    older runner image fails at `Print omni-dev version`. Every leg checks it ran on the
    architecture it names (`runner.arch` and `uname -m`), as job 6 does, so a leg cannot
    pass as ARM64 on another runner.
  - **A cache hit skips the install.** `actions/cache` restores `~/.cargo/bin/omni-dev` and
    "Download pre-built binary" is then skipped; the key holds the version, not the action's
    code. That holds for every leg, x86_64 included, and none works around it: the asset's
    name, the archive layout and the binary are exercised on the first run for a version (a
    new release, or an entry that was evicted or never written for that ref), not on each
    run. A `cache-prefix` made of a hash of `action.yml` and `scripts/*.sh` was tried on the
    ARM64 legs and dropped: the gap is not ARM64's, so fixing it there alone leaves the
    matrix inconsistent; the glob has to be kept in step with the install code by hand; the
    weekly run would still hit an entry; and each miss reinstalls once per scenario, since
    the entry is saved only in the post step. If it is wanted, do it for every leg that
    exists to run the install, and decide the schedule and a run-id prefix then.
  - The `latest` ARM64 leg shares the release-asset lag the other `latest` legs have, and
    may see it for longer or shorter, as the asset can be uploaded by another job than the
    x86_64 one: a red `latest` leg right after an omni-dev release, with "has no pre-built
    omni-dev-linux-arm64.tar.gz", is a re-run, not a regression.
- **Version resolution (#1, #40)**: `version: latest` costs one call to the GitHub API
  (`.../repos/rust-works/omni-dev/releases/latest`), and one more request if the API gives no
  release in any attempt (the redirect fallback, below); a pinned version makes none. Made
  unauthenticated from a shared runner address it hit the 60/hr limit and failed the whole job,
  so the step sends `github-token` (default `github.token`, 1000/hr) and tries three times,
  sleeping 3s then 6s (none after the last) before the redirect fallback; if that fails too,
  one error names both failures, the input to check and the other way out, pinning `version`.
  Each call is bounded (`--connect-timeout 10 --max-time 30`), so a hung connection is
  retried instead of waited on until the job's timeout. Rules:
  - The token reaches the script through `env: GH_TOKEN`, never as an expression in the script.
    The runner evaluates every `${{ }}` in a `run:` block, in a comment or a message, and a
    backslash does not escape one: a message that wrote the expression would show the masked
    token (`\***`) instead, and an empty `${{ }}` in a comment fails the step. The test fails if
    the script holds any expression: the version reaches it through `env: VERSION` too (#39).
  - The token does reach curl's arguments (`-H "Authorization: Bearer ..."`); the environment only
    keeps it out of the script text. It is the job's own masked token, as in commit-check's step.
  - `curl` and `jq` each end in `|| true`: under `bash -e` a refused connection or a gateway's HTML
    error page would otherwise end the step with a bare exit code before the retry or the message.
    The test scripts each shape (curl failing or timing out, a body that is not JSON, JSON with no
    `tag_name`). `jq` also hides its stderr there, so a runner without it would look like a rate
    limit: the step checks for `jq` first and says so.
  - No `--fail` on that curl: a 403 keeps its JSON body, which is where GitHub's reason ("API rate
    limit exceeded", "Bad credentials") comes from, and the warning prints it.
  - A leading `v` is dropped from the value however it was obtained (#38), once, after the
    `latest` branch: `VERSION="${VERSION#v}"`. A pin written as a release tag (`v0.45.0`) used to give
    `release-tag=vv0.45.0` (a 404 that the platform step reports as a missing asset), its own cache key,
    and a `cargo install --version` that cargo refuses ("not a valid SemVer requirement"). Only one `v`,
    and only a leading one: `0.46.0-dev` keeps its. Keep the strip out of the `latest` branch, or a pin
    skips it; `tests/resolve-version-step.test.sh` runs both spellings and checks the input says so.
  - The release-asset downloads stay unauthenticated on purpose. They are `github.com/.../releases/
    download/` URLs, not API calls, so the limit in #1 does not apply to them, and curl drops
    `Authorization` on the redirect to the asset CDN: the header would only send the token somewhere
    it buys nothing.
  - **Redirect fallback (#40)**: a spent limit can last up to an hour, longer than the attempts can
    wait, so after the third failure the step reads the tag from the redirect of
    `https://github.com/rust-works/omni-dev/releases/latest`. The API stays first (it is the
    documented interface and the redirect is not), so the fallback only changes a run that would have
    failed, and the one warning it logs says it did, with the API's reason. Rules:
    - One request, no `-L`: `-w '%{http_code} %{redirect_url}'` gives the status and the `Location`,
      and following the redirect would fetch the tag's HTML page, which the step has no use for and
      is one more request that can fail or be throttled. No token: it buys nothing on github.com, as
      with the asset downloads. The call ends in `|| true` for the API call's `-e` reason, and the
      answer is read with `read` and `[[ =~ ]]`, no jq. A runner with no jq still fails first, with
      the jq message, although the redirect needs none: the API runs first and the guard keeps a
      missing jq from being reported as a rate limit.
    - The URL is read from a header, so it is used only if it is exactly
      `https://github.com/rust-works/omni-dev/releases/tag/v<N>.<N>.<N>`, with an optional semver
      pre-release (`-` and dot-separated identifiers of letters, digits and hyphens). The tag goes
      into a cache key, a download URL, `cargo install` and `$GITHUB_OUTPUT`, and is stricter than
      the API path, which takes any `tag_name` as it is, because this one comes from a URL. A login
      page, no redirect, another repository or host, `nightly`, build metadata (`+`), a path, query
      or fragment after the tag, or the tag URL inside a longer string is rejected, and the error
      says what the redirect gave (`HTTP <status>`, and the URL it went to).
      `tests/resolve-version-step.test.sh` has a case for each of 35 such shapes. It was checked
      against mutations of the step, each of which fails it: either anchor of the regex dropped,
      each unescaped dot (the host's, the version's), a suffix that takes any text or empty
      identifiers, `http`, any tag, `-L`, the token sent to github.com, no `|| true` on the
      redirect call, no timeouts. Keep a case for any shape you allow or refuse.
    - "Latest" means the same on both sides: each is the repository's Latest release, which leaves out
      drafts and pre-releases. Checked on 2026-10-04 where the newest release is a pre-release
      (neovim/neovim, rust-lang/rust-analyzer) and where the Latest flag is not on the newest by date
      (dotnet/runtime): the API and the redirect gave the same tag every time. omni-dev has no
      pre-release to try, and drafts are invisible without a token.
    - A bad `github-token` (401) takes this path too, so it no longer fails the job: it resolves from
      the redirect and logs the warning, which names the API's reason ("Bad credentials") and says to
      check the token. That is the point of the fallback (the step resolves whatever the API says),
      and also how the `latest-redirect` job makes the API fail on demand. The warning says the API
      "gave no release", not that it did not answer, because a refusal is an answer.
    - Whether github.com throttles the redirect on a runner's address is not known. It cannot make a
      run worse (the fallback runs only after the API failed), but it was not measured from a runner
      when this was written. The `latest-redirect` job is that measurement and keeps checking, weekly
      too: scenario 10 sends the token `not-a-token`, which the API refuses with 401 whatever the rate
      limit and without spending any, so its three attempts fail on demand and the redirect must
      answer; the job asks the API directly, with the workflow token, what "latest" is, and the two
      must agree. A second run of the action is not the control: with the fallback it would use the
      redirect too whenever the API failed, and a second `latest` install would break the one
      omni-dev version per job rule. The 401 is recorded just before 10 and asserted at the end,
      because a job cannot read its own log. What 10's log says (the warning) is pinned only by the
      unit test, as is that `github-token` reaches the step; nothing in `failure-messages` reads a
      `##[warning]` line, and a reader for one would let it assert the warning.
- **No first-class shard mode (decided in #24)**: there is no `mode: shard` / `mode: report`,
  and none should be built until a real adopter has a sharded workflow on this action and
  names what was awkward. The README's sharded example, kept honest by `e2e-sharded.yml`, is
  the supported shape. The reasoning, so it is not re-derived:
  - A composite action cannot own the matrix, the artifact hand-off or the `needs`, so a
    mode would be two invocations in jobs the caller still writes, saving the shard job's
    install and partition steps (about 10 lines per shard job).
  - A reusable workflow has fixed inputs, where real callers need per-architecture setup and
    steps around the action (succinctly's x86_64 leg reclaims disk first; its ARM64 leg builds
    omni-dev from source, `use-prebuilt-binary: false`, which it can drop on omni-dev 0.46.0
    or later, #20). A local `uses: ./` inside one resolves
    against the caller's checkout, so it could not be tested against a pull request's own
    `action.yml`.
  - Nobody had adopted `shard-reports` when this was decided. rust-works/succinctly, the case
    behind it, still ran fat mode, pinned to omni-dev 0.43.0 with `fail-under-lines: 55`; in
    thin mode that gate needs 0.45.0 or later (`shard-reports` itself uses no omni-dev flag).
  - nextest stays the caller's choice (the action never runs it), and the caller owns
    `--partition count:i/N`. `setup-commands` and `extra-test-commands` stay fat-mode inputs.
  - nextest skips doctests. One more job on nightly, `cargo llvm-cov --doc --lcov`, uploading
    its own `shard-*.lcov`, recovers them, because the join accepts any number of files. On
    the shard fixture with a doctest added, the nextest shards gave 87.50% and the join with
    that report 100.00%. Checked locally, not on a runner; `llvm-tools-preview` must be a
    component of the nightly toolchain or cargo-llvm-cov stops at an interactive prompt.
  - If it is built: `mode: full|shard|report` (`full` the default, today's behaviour);
    `shard` takes `shard-index` and `shard-count`, skips every pull-request, baseline and gate
    step, and runs `cargo llvm-cov nextest <test-args> --partition count:i/N --lcov`, then
    uploads `coverage-shard-i`; `report` downloads `coverage-shard-*` with `merge-multiple` and
    runs thin mode with `shard-reports`. Move `e2e-sharded.yml` onto it with its assertions
    intact, and add an `integration.yml` scenario per bad input.
- **Flags that need a new omni-dev**: one guard step asks omni-dev whether it accepts each
  flag the run needs, failing with the fix rather than letting clap report an unknown
  argument later. It runs before the coverage run, and only when a flag is needed (a
  fat-mode push calls no `omni-dev coverage`, so an old pin must keep working there). It
  reports every missing flag and asks only about the ones the run needs.
  - `--fail-under-lines` (0.45.0): thin mode with the line gate on. `latest` can
    resolve to a release without it. Do not tag a release of this action until an
    omni-dev release with the flag exists, or every thin-mode caller on the default
    gate would fail.
  - `--output` (0.32.0): every `pull_request`, fat or thin, because the comment diff
    runs even with `comment: false`, so no input turns this one off. 0.32.0 is the
    floor for the whole pull-request path, not just `-o` (0.29.0 to 0.31.0 have
    `--format`, and the path passes no flag 0.32.0 lacks). Ask omni-dev, never read the
    version: the guard must keep working when `latest` moves.
  - `--ignore-filename-regex` (0.33.0): the `ignore-filename-regex` input set AND a diff
    runs (a `pull_request`, or thin mode with the line gate on). That implies one of the
    other two needs, so the step's `if:` did not change. 0.32.0 is the newest release
    without it.
  - **It asks, it does not read `--help`** (#36). The help is a proxy: omni-dev hides a
    deprecated flag it still accepts (`--format` on 0.45.0), which a help match calls
    missing and no upgrade fixes, and a description line that begins with a flag's name
    reads as the flag being there. clap rejects an unknown argument before it reaches
    `--help` and still recognises a hidden one, so `has_flag <flag>` runs `omni-dev coverage
    diff <flag> x --help` and reads clap's message. `error: unexpected argument '<flag>'
    found` or `error: unrecognized subcommand 'coverage'` (or `'diff'`) means missing; anything
    else (exit 0, `invalid value 'x'`) means present. The dummy `x` is never a real value, so
    the step is not coupled to omni-dev's enum names (a valid `--output markdown` would be,
    and a rename would read a present flag as missing). `--help` follows the value, and
    `--report` is required, so the probe does not run a diff. The wording is the same on every
    release from 0.29.0 to 0.45.0, swept by hand for #36 (0.28.0 says `unrecognized
    subcommand 'coverage'`), and the floors it finds are exactly 0.32.0, 0.33.0 and 0.45.0. A
    flag whose value `x` is valid (a free-form regex, `--ignore-filename-regex`) answers exit 0
    and the whole help, which is still "present".
  - **It fails open**: if clap rewords the message, or a probe fails in a way nobody has
    seen, the flag counts as present and the run gets clap's own error later, as before the
    guard existed. The integration legs that expect a stop (`0.28.0`, `0.31.0`,
    `OLD_OMNI_DEV`) run pinned releases, whose wording cannot change, so they do NOT notice a
    newer omni-dev rewording it (#36 first said they would; they cannot). What notices is
    `deprecation-control`'s D3 step: it runs on `latest` and fails if omni-dev stops saying
    `unexpected argument '<flag>' found` for a flag that cannot exist, naming `has_flag` as
    the thing to update. A failing probe on an omni-dev below 0.29.0 (no `coverage`
    subcommand) counts as "none of these flags are here", and the message still names the
    omni-dev found, read by the separate `--version` call. That is safe because `Print
    omni-dev version` has already proved the binary runs. The probe captures stderr, so the
    line that decided is echoed to the log either way (`omni-dev said: ... [<flag> counted as
    missing|present]`): a probe that failed some other way, and so counted as present, can be
    read there.
  - **The probe sets `NO_COLOR=1`.** A caller that sets `CLICOLOR_FORCE=1` (some do,
    workflow-wide) gets clap's message with the flag wrapped in escape codes
    (`'\e[33m--output\e[0m'`), which a literal match never finds, so the guard would fail open
    on exactly the omni-dev it should stop. `NO_COLOR` wins over `CLICOLOR_FORCE`. Keep it if
    you touch the probe. `|| true` on the capture says the status is ignored: clap exits 2
    whether the flag is there or not.
  - `tests/guard-step.test.sh` runs the step against a stub `omni-dev` that answers the probe
    the way clap does, and also prints a plain `coverage diff --help` the step must never ask
    for: a flag accepted but hidden from it, and a help whose lines name a flag omni-dev lacks,
    would fool a step that went back to reading it (the case list holds both, each with a
    control). It also pins forced colour, the fail-open, "every missing flag" and that a flag
    the run does not need is not asked about, and replays what the real releases answered
    (`tests/fixtures/omni-dev-probe/`: 0.28.0, 0.31.0, 0.32.0, 0.33.0, 0.44.0, 0.45.0; the header says
    how to refresh one, with `NO_COLOR=1`, as the step asks), so the wording the step matches is
    held to what omni-dev prints; each fixture is also checked for the message its replay
    claims, since a fail-open step passes an empty one. The tests do not inherit `NO_COLOR` or
    `CLICOLOR_FORCE` from the shell running them, or a developer's `NO_COLOR` would turn the
    forced-colour cases into no-ops. It
    does not reach the step's `if:`, which `output-flag` covers. A new flag is one more
    `has_flag` call (a plain long flag: it goes into the match as a fixed string) and a case
    there. What it cannot tell: a flag that still works but is deprecated reads as present,
    which is right for this step and is what the deprecated-flag checks below are for.
- **Test helpers and step extractors**: each `tests/*.test.sh` sources `tests/test-lib.sh`
  and ends on `summary`, whose status is the test's exit status; do not define `ok`, `bad`,
  `eq` and the rest in a test again. The command checker is `pass` (and `fail` for one that
  must fail), not `check`: `tests/assert-lib.sh` defines a different `check <label> <expected>
  <actual>` for the e2e workflow, and a file should not source both. `test-lib.test.sh` runs
  failing cases because no other test does, and every test ends on `summary`: one that
  returned 0 would pass them all. A test that runs a step's script, or matches on a step or
  an input, reads it with `tests/step-lib.sh`, which takes the file from `$ACTION`. Rules:
  - It reads the layout `action.yml` has (a step at 4 spaces, its keys at 6, the `run: |`
    body at 8) and refuses the rest: nothing on stdout, the reason on stderr, status 1. Call it
    as `X="$(step_run 'Step name')" || exit 1`; a `-z` check on the result is not needed, and a
    fourth awk copy would read the wrong thing without saying so. `run: |`, `|-` and `|+` are
    all read; an inline `run:` (`Print omni-dev version` is one), a folded `>`, a body not at
    8 spaces, a step with no `run:` and a name that is missing or doubled are refused.
  - A change to that layout is an edit to `step-lib.sh` and `step-lib.test.sh`, not to each
    test. A comment at 4 spaces or less in the middle of a step would end it early; there is
    none today.
  - The awk is POSIX: the ubuntu runners' default is mawk, which has no regex intervals
    (`{n,m}`) or `gensub`. Names reach awk through the environment, not `-v`, so a backslash
    in one is not an escape.
- **Integration workflow**: `integration.yml` asserts each scenario's step `outcome`
  (not `conclusion`, which is `success` under `continue-on-error`). Three rules keep it
  honest. Run one omni-dev version per job: `actions/cache` saves in a post step, so a
  second version installed over `~/.cargo/bin/omni-dev` poisons the first version's
  key. Give every expected failure a control that differs in one input and must
  succeed, plus a file check showing where the action stopped. `OLD_OMNI_DEV` is the
  newest release without `--fail-under-lines`, so it stays put when the `0.45.0`
  floor rises; change it only if the guard starts detecting a newer flag.
  - The poisoned-cache rule is checked by `tests/assert-omni-dev-version.sh <version>`, which
    the twelve jobs that assert a scenario's outcome end on, in `integration.yml`,
    `pr-paths.yml` and `e2e-sharded.yml`. `arm64-release-without-asset` installs nothing
    and `deprecation-control` has one install and asserts no outcome, so neither calls
    it. It needs the version line to start with `omni-dev <version>` and
    the number to end at a space or the end of the line (the line is `omni-dev 0.45.0
    (b5445b9 2026-10-03)`, so a plain equality check would be wrong). The old
    `grep -qF` was a substring match, which would have let a pin that is a prefix or a
    suffix of another release's number pass for it (`0.4.1` for `0.4.10`, `1.2.3` for
    `11.2.3`); no release has that shape today. Rules:
    - Call it as `bash tests/assert-omni-dev-version.sh "$VERSION" || status=1`. A bare call
      ends the step under Actions' `bash -e` before the step's other checks report.
    - Pass the pin, or the action's `version` output for a `latest` leg (a bare release
      number). A step that failed exposes no output, so the version arrives empty; that is
      a usage error, not a match for every binary as `grep -qF ""` was.
    - A new leg or job that runs an omni-dev gets this call at the end of its checking
      step. `tests/assert-omni-dev-version.test.sh` holds the cases (prefix, suffix, a
      dot that is not a wildcard, a binary that is missing or fails).
  - The `--output` guard acts only on a `pull_request`, so the `output-flag` job (a
    matrix: `0.28.0`, the newest release with no `coverage` subcommand at all, `0.31.0`,
    the newest with `coverage diff` but without the flag, and `0.32.0`, the floor)
    runs on EVERY event and expects by event: the old legs fail at the guard on a
    pull request and must succeed on any other, so a guard that over-fires is caught
    too. The `0.32.0` leg is the old legs' control (only `version` differs). The
    other-event expectations first run on the push after a merge. The matrix cannot
    read `env`, so its versions are literals; `failure-messages` repeats them.
    The 0.28.0 binary links `libasound.so.2` (0.31.0 does not), so if the runner image
    ever lacks it the leg fails at `Print omni-dev version` with a shared-library
    error, not at the guard.
  - On the failing leg, the file check is that no report and no `coverage.md` exist:
    the scenario is sharded, the guard runs before the combine, and clap's failure in
    the comment step would leave a combined report and an empty `coverage.md`.
- **Failure-message assertions**: a step cannot read its own job's log and a composite
  action exposes no output for a failing step, so the outcome and file checks pin
  the step order, not the text a user reads. The `failure-messages` job (`needs`
  every scenario job it reads, so it is skipped while one is red) reads their
  finished logs with `tests/job-errors.sh` and asserts the shard-pattern error
  names the pattern, the `--fail-under-lines` guard names the omni-dev it found and
  both ways out, and (on a pull request only, the one event that runs it) the
  `--output` guard names the omni-dev it found, the 0.32.0 floor and the way out, and
  the same for the `--ignore-filename-regex` guard (0.33.0 floor, both ways out).
  Match the found version as its own fragment: `omni-dev --version` can carry a
  commit and date after the number. Rules:
  - Read only the `##[error]` lines. The log also echoes every step's script, which
    holds the same message text whether or not the step ran it, so grepping the whole
    log passes for the wrong reason.
  - Each check needs all its fragments in ONE message, so two errors cannot add up.
  - `gh` 2.97 and later refuse to print an API response that holds terminal escape
    sequences, and a runner log is full of ANSI colour. `job-log.sh` passes
    `--allow-escape-sequences` when `gh api --help` lists it (an older `gh` has
    neither). Detect it from captured help, not a `| grep -q` pipe: `grep -q` can
    exit first and `pipefail` then fails the pipeline.
  - It is the only job with `actions: read` (job-level `permissions` drops the rest,
    so it also lists `contents: read` for the checkout). Keep it that way.
  - It names the jobs it reads, including the thin-mode matrix versions and the
    `output-flag` and `ignore-filename-regex-flag` legs without the flag. Renaming a
    job or changing the matrix fails it loudly (no job of that name); a new matrix leg
    is not checked until it is added to the list.
  - A scenario that exists for its message gets an assertion here; edit a message
    in `scripts/combine-shards.sh` or the guard in `action.yml` and this job
    names the fragment that went missing.
- **Deprecated flags**: omni-dev keeps a deprecated flag working and warns only at run
  time (`warning: --format is deprecated; use -o/--output instead`), and hides it from
  `--help`, so two checks look for one, from two sides: the source for the flags it was
  told about, and the logs for any. Rules:
  - `tests/check-deprecated-flags.sh` (run by `test.yml` on every pull request) fails
    when `action.yml` or `scripts/*.sh` passes omni-dev a flag in the list at the top of
    the script; today that is `--format` (use `-o/--output`). When omni-dev deprecates
    another, add a `flag|use instead` line (a plain long flag: anything else is
    refused, not matched as a pattern); nothing else tells this check.
  - A hit is the flag as a whole word anywhere in the file, not only on the line that
    runs omni-dev: flags are collected in `args=(...)` and `omni-dev "${args[@]}"` runs
    later. `--report-format` is not a hit. Full-line `#` comments are skipped; nothing
    else is, echoed text included, so do not spell a deprecated flag in a message, and
    write another command's `--format` another way (`git log --pretty=format:`).
  - The test rewrites the real `action.yml`'s `-o` call sites back to `--format`,
    asserts the copy differs and that every rewritten line is reported, so reworking
    those call sites fails the test instead of leaving a check that passes on
    fixtures and finds nothing in the real file.
  - The `failure-messages` job's second step reads the logs with
    `tests/job-deprecations.sh`: on a pull request no job of the run may have logged a
    deprecation warning. It reads every job that finished green except the control,
    found through the API, so a new job or matrix leg is read without being added to a
    list (a job that stops at a guard logs none, which is its right answer). A new
    omni-dev deprecation turning it red on an unrelated pull request is the check
    working, not a flake: stop passing the flag and add it to the list above. Another
    tool's `warning: ... deprecated` in these logs would turn it red too (none does
    today), and its message says to look at the line.
  - A warning is a line that begins with `warning:` right after the runner's timestamp
    and holds "deprecat" in any case. That leaves out the colour-coded echo of a step's
    script (which can hold the same words), the runner's `##[warning]Node.js 20 is
    deprecated` and node's `DeprecationWarning`, which every log carries. These shapes
    are from real logs, and the test fixture holds one of each.
  - An empty read proves nothing unless the steps ran, and a skipped step logs
    nothing: a push log holds none of the diff steps' output. So each job that runs the
    diffs shows with a file check that the comment and percentages diffs ran
    (`coverage.md`, `coverage.json`), which is why the check is pull-request only. The
    thin-mode scenarios share a workspace and the files keep their names, so there the
    files show that at least one scenario got there; the diffs get the same flags in
    each, so one is enough. A new job that runs the diffs gets a file check of its own.
  - Nor does an empty read prove the reader can see one. The `deprecation-control` job
    passes `--format` to omni-dev directly, on `latest`, and the job asserts the warning
    is found on every event. If that fails, omni-dev either reworded the warning
    (update `job-deprecations.sh`) or removed the flag (retire the control). The same job
    runs D3, the control for the guard's probe (see "Flags that need a new omni-dev"): it
    needs the same `latest` install, and it is unrelated to the warning.
  - The percentages diff in `action.yml` no longer sends stderr to `/dev/null`: that
    hid its warning, which is how #14 missed that call site. The step still never
    fails the build. Keep it that way.
  - Only `integration.yml` is read. `pr-paths.yml` and `e2e-sharded.yml` run the same
    action, so the same call sites, but their jobs run with the README's permissions,
    not `actions: read`.
- **Fat-mode integration job**: the action runs cargo at the workspace root and a
  caller cannot give a composite action's steps a working directory, so the job
  copies the fixture crate there (it refuses to run if a root `Cargo.toml` or `src/`
  exists). It sets `recompute-baseline: false`: the fixture is not in git history,
  so the merge-base worktree a pull request builds would have no `Cargo.toml`
  (`pr-paths.yml` covers the recompute with a crate it commits itself). The
  action writes `codecov.json`, `coverage-summary.txt` and `coverage.md` to fixed
  names, so `tests/move-outputs.sh` moves each scenario's outputs to `out/<id>/`
  before the next runs (the merge log included); add any new fixed-name output to its
  list. The fixture's
  functions are each reached by a different part of the run (`main_run`,
  `extra_only`, `setup_only`, `never`), and its tests leave marker files so an
  expected failure can show where it stopped. The gates of 40 and 80 are set around
  its measured 58.3% (33.3% without the extra command), so re-measure if the
  fixture's lines change or a toolchain attributes them differently.
- **PR-paths workflow** (`pr-paths.yml`): a separate workflow so `pull_request` can be
  path-filtered (no coverage comment on a pull request that cannot change the action)
  while `push` is NOT, because every main commit must publish a baseline or a later
  pull request based on it misses. Pushes get a per-SHA concurrency group so a burst
  of merges cannot cancel the run that would have published. It is path-filtered, so
  it must never be a required check. Rules:
  - Every scenario uses the same report basename (in its own directory). The action
    reads `baseline/<basename of report>`, so a different basename never finds the
    baseline that was published.
  - The `pull-request` job runs with exactly the permissions the README lists
    (`contents: read`, `pull-requests: write`), not `actions: read`. The repository
    is public, so a pass shows public callers need no more, not that a private
    caller does not.
  - A baseline hit is not assumed: it needs a published baseline for the merge-base,
    which the first pull request cannot have and a recent merge-base may still be
    producing. `tests/expected-baseline.sh` (which walks the same first-parent ancestors
    through `gh` and not through the lookup's own code) is asked before the scenarios and
    again in the last step, and the lookup must land within the span of the two answers: a
    baseline can be published while the job runs (the `push` run for the merge-base
    finishing), so one answer taken at the end could expect a nearer commit than the lookup
    could have seen. When nothing changed the answers agree and it is exact: the nearest
    baseline, or a miss. Both paths are tested whichever one a run takes. On a hit the
    baseline's `TN:` is the commit the lookup found, the comment must carry the ancestor
    note exactly when that is not the merge-base's, and the totals are recomputed from the
    downloaded file, so the assertions survive edits to the fixture.
  - P7 and P8 make the walk deterministic. Their `base-ref` is a commit made with
    `git commit-tree` (a child of the merge-base with its tree, on no branch, which omni-dev
    diffs from as it would the merge-base), so no run was ever for it. P8 has the walk
    off and must miss on every run whatever `main` holds; P7 can only be answered by an
    ancestor and is held to the API. P9 names a workflow the API does not know and must be
    a miss, not a failure, under the README's permissions. The comments are off, so the
    ordering rule below is unaffected.
  - The diff is `merge-base..HEAD`, so a pull request's own changes would decide the
    patch gate. `write-pr-fixtures.sh` commits a 10-line `patch-fixture.txt` locally
    (never pushed) so the patch always has known added lines, and instruments
    `LICENSE` as the file whose coverage flips with no change to its lines (an indirect
    change, shown only with `all-files: true`); the head fixtures fail fast if a pull
    request edits it. The job is skipped for forks and Dependabot, whose tokens cannot
    write the comment.
  - Scenarios P1, P2 and P3 post under one header and render the same comment on a
    miss, so each is read back and deleted before the next. Otherwise a scenario that
    stopped posting would pass on the previous one's comment.
  - P5 and P6 show `ignore-filename-regex` reaching the patch gate and the comment. They
    run after P1 and add a second committed file (`write-pr-fixtures.sh extra`:
    `patch-extra.txt`, every added line uncovered, with a `shard-3.lcov` of its own), so
    the patch is 8 of 20 lines (40%), and 8 of 10 (80%) once the filter drops the second
    file: a gate of 70 tells them apart and only P5 passes. The filter must not empty
    the patch instead. omni-dev lets a patch with no measured line through the gate,
    which is a vacuous pass (its own tests call that a trap), and a later omni-dev may
    change it. They run after P1 to P4 so those never see the file (their assertions are
    on 10 lines at 80%), and `comment: false` leaves no comment to read back.
  - The recompute needs a commit that holds a crate, which the pull request's history
    does not, so the job commits `delta-crate`'s base and head itself and passes the
    first as `base-ref`. Its numbers are then the job's own. Unlike the fat-mode crate
    its tests need only `cargo test`, because the recompute replays only `test-args`.
  - The hit path cannot be shown before a baseline exists on `main`: the pull request
    that adds this workflow shows the miss path, the `push` run after it shows the
    publish, and the first later qualifying pull request shows the hit.
- **E2E sharded workflow** (`e2e-sharded.yml`): the real topology the README describes
  (shard jobs → `coverage-shard-N` artifacts → an aggregation job with `pattern` +
  `merge-multiple` → the action); `pr-paths.yml` covers the same loop on hand-written
  lcov. It follows `pr-paths.yml`'s rules (push unfiltered, pull request path-filtered,
  never a required check, per-SHA concurrency on pushes, the baseline lookup asserted
  against the Actions API through `tests/baseline-lib.sh`). What is particular to it:
  - It publishes `coverage-baseline-e2e-sharded` and comments under `e2e-sharded`,
    apart from `pr-paths.yml`: the baseline lookup is per workflow, and two uploads
    of one name in a run conflict.
  - The patch is the whole fixture crate, committed locally by the aggregation job
    (`prepare-shard-crate.sh --commit`, never pushed), so the patch gate cannot pass
    vacuously whatever a pull request changes. `base-ref` would also fix the diff, but
    it keys the baseline lookup and would force a miss on every run. Every job copies
    the crate to the same path under the same workspace root, which is what lines the
    shards' report paths up with the diff.
  - A push runs every test; a pull request skips `t4_delta`, so a baseline hit shows
    the total falling (87.5% to 65.6%) and the comparison is shown the right way round.
    A change to which tests run must change the expectations marked `delta`.
  - Real `cargo llvm-cov` lcov has no `TN:` line and no newline after its last
    `end_of_record`. The shard job inserts `TN:<sha>` with `perl -pi`, which keeps the
    missing newline, so the join's glue case runs for real and a downloaded baseline
    says which commit it was published for.
  - The gates of 55 and 80 sit around the head's measured 65.6% (one shard alone is at
    most 43.75%); re-measure if the fixture's lines change. 21/32 is exactly 65.625,
    which omni-dev and `lcov-percent.sh` round to different neighbours, so compare
    their figures with a tolerance of 0.02, not 0.01.
  - The checking steps source `tests/assert-lib.sh` rather than inlining `check` and
    `assert` as the other workflows do: three steps need the same helpers, and what the
    numeric ones do with a missing value decides whether a gate's assertion can pass
    vacuously. `lt` and `ge` succeed only for two numbers: awk compares `null` (what
    `jq -r` prints for a missing field) as text, which made `ge` pass quietly. `assert`
    prints what a failed command printed, and the steps print the measured figures, so a
    first red run on a runner can be read without a re-run.
  - `prepare-shard-crate.sh --commit` fails if a file it copied was not committed
    (`git add` skips an ignored file silently), so a `.gitignore` rule cannot shorten the
    patch unnoticed.
  - E1's sticky comment is left on the pull request on purpose, as the evidence.
  - Each failing scenario differs from E1 in one input, and the gate it failed is
    attributed from its own numbers (E2's patch is under its gate while its line total
    clears the other; E3 the reverse), since a composite action exposes no output for
    a failing step.
  - The hit path needs two merges, as `pr-paths.yml`'s: the pull request that adds
    the workflow shows the miss path, the `push` run after it publishes, and the first
    later qualifying pull request shows the hit.
- **`ignore-filename-regex`** (#3): one input, threaded into EVERY `omni-dev coverage
  diff` the action runs: `Build coverage diff` (one `args` array feeds its markdown and
  its json call), `Enforce patch-coverage gate` and `Enforce line-coverage gate (thin
  mode)`. The issue named the first two; the third mirrors the same parse-affecting
  flags, and omni-dev gates `--fail-under-lines` on the head report after the filter, so
  without it the thin-mode gate would disagree with the comment's total. A new `coverage
  diff` call site takes it, with `--strip-prefix` and `--report-format`, or its
  percentage is measured over other files than the comment's. Rules:
  - The value goes in through `env:` and is read as `"$IGNORE_FILENAME_REGEX"`, not
    interpolated into the script as `strip-prefix` is: a regex is full of `\`, `$` and
    quotes that bash reinterprets inside double quotes (`\\` becomes `\`). The guard
    step reads it the same way.
  - It is passed as `--ignore-filename-regex=<value>`, one argument. As two, a pattern
    that starts with `-` (`-sys/`, for the `*-sys` crates) is read by clap as a flag
    and the step fails with "unexpected argument '-s'". Integration scenario 8a's first
    pattern starts with `-` so that a return to two arguments fails it.
  - It is not passed to `cargo llvm-cov`: the fat-mode line gate and the summary count
    every file, and the README says so. `cargo llvm-cov --ignore-filename-regex` matches
    absolute paths, so the same string would mean something else there; give it an
    input of its own if it is wanted.
  - Commas split the patterns (omni-dev's `value_delimiter`), so a pattern cannot hold
    one (`a{1,3}` fails as an invalid regex); omni-dev ignores an empty piece. Nothing
    else separates them and nothing is trimmed: a newline or a space is part of the
    pattern, so a `|` block or `a, b` filters nothing, silently. That was left as
    documented (README, input description) rather than normalised: the issue specifies
    a comma-separated list, normalising would alter a pattern that holds a space, and
    the file stays in the comment, visibly, as it did before the input existed.
  - The two gates differ when a filter removes everything: the patch gate passes (an
    empty patch is not an error to omni-dev, and the comment says so), the thin-mode
    line gate fails with "no executable lines". Documented in the README.
  - Tests: the `ignore-filename-regex` job (8a, a gate of 70 passes with LICENSE
    filtered out, 8b the control without the filter fails: 50% against 100%),
    `ignore-filename-regex-flag` (9: 0.32.0 is stopped by the guard on a pull request
    only, 0.33.0 is its control), `pr-paths.yml` P5 and P6 for the comment and the
    patch gate, and `tests/guard-step.test.sh` for the probe and the floor.
- **Gate ordering**: the comment-building diff is run WITHOUT `--fail-under-patch`
  so a failing gate never blocks the comment; the gate is enforced by a separate
  diff invocation after the comment step.
- **Secrets** (e.g. the codecov token) must be passed as inputs — composite
  actions cannot read `secrets` directly.

## Commit and PR Guidelines

This project uses conventional commits with required scopes. See `.omni-dev/commit-guidelines.md` for details.

**Scopes**: `action`, `docs`, `ci`

**Example commits**:
```
feat(action): add fail-under-patch input
fix(action): handle missing baseline artifact gracefully
docs(docs): add thin-mode usage example
```
