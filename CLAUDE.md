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
- `tests/download-step.test.sh` - Runs the "Download pre-built binary" script read out of `action.yml` against a stub `curl` that serves a tarball and a zip with the layout of the real release assets, and a stub `find` that lists in either order, with `HOME` and every `/tmp` in the script pointed at a directory of the case's own: the file left at `~/.cargo/bin/omni-dev` is the right one, by content, and executable, and an archive with no `omni-dev.exe` fails with a message (`test.yml` runs that)
- `tests/guard-step.test.sh` - Runs the "Check omni-dev supports the flags this run uses" script read out of `action.yml` against a stub `omni-dev` that answers the probe as clap does, and against the real answers in `tests/fixtures/omni-dev-probe/` (`test.yml` runs that)
- `tests/print-version-step.test.sh` - Runs the "Print omni-dev version" script read out of `action.yml` against a stub `omni-dev` that replays the captured loader output in `tests/fixtures/omni-dev-loader/` and a stub `getconf`: the glibc the binary needs, the one the runner has and the two ways out (`test.yml` runs that)
- `tests/resolve-version-step.test.sh` - Runs the "Resolve omni-dev version" script read out of `action.yml` against a stub `curl` that replays scripted responses (the API's, then the redirect's) and a stub `sleep` (`test.yml` runs that)
- `tests/recompute-worktree.test.sh` - Runs the "Compute baseline from merge-base (fallback)" script read out of `action.yml` with the real `git` in a throwaway repository against a stub `cargo` that can fail, and checks what is on disk afterwards: the `../base` worktree is gone after a recompute and after a failing one, a second recompute in the same workspace succeeds and writes the same baseline, a leftover worktree is cleared, and a plain directory named `base` is kept (`test.yml` runs that)
- `tests/input-steps.test.sh` - Runs the steps that read a caller's input (the `ignore-filename-regex` check, the test, setup and extra commands, the report, merge-base, recompute, diff and the gates) read out of `action.yml` against stub `cargo`, `git`, `omni-dev` and `sudo`, with hostile values that must stay data (`test.yml` runs that)
- `tests/check-run-expressions.sh` - Fails when a `run:` body of `action.yml` or of a workflow in `.github/workflows/` holds a `${{ }}` expression (`tests/check-run-expressions.test.sh` tests it; `test.yml` runs both)
- `tests/combine-shards.test.sh` - Plain-bash tests for that script (`.github/workflows/test.yml` runs them)
- `tests/llvm-cov-ignore-steps.test.sh` - Runs the five steps that run `cargo llvm-cov report` (the lcov, `codecov.json`, the summary, the line gate and the recompute's report), read out of `action.yml`, against a stub `cargo`, and checks the one `--ignore-filename-regex=<value>` each gets, or none when the input is empty; it fails when another step runs `cargo llvm-cov report` (`test.yml` runs that)
- `tests/test-lib.sh` - The helpers every `tests/*.test.sh` sources: `ok`, `bad`, `eq`, `has`, `lacks`, `pass`, `fail`, the closing `summary` and `work_dir` (the scratch directory) (`tests/test-lib.test.sh` tests it, including how a failed case fails; `test.yml` runs that)
- `tests/step-lib.sh` - `step_run`, `step_block`, `step_field`, `step_map` and `input_block`: the one reader of `action.yml`'s steps and inputs, for the step tests; it refuses a layout it cannot read (`tests/step-lib.test.sh` tests it; `test.yml` runs that)
- `.omni-dev/` - Project guidelines for commits and PRs
- `.github/workflows/commit-check.yml` - Dogfoods the commit-check action on this repo (runs on `merge_group` too: `Validate Commit Messages` is a required check of the merge queue)
- `.github/workflows/integration.yml` - Runs the action itself (`uses: ./`) in thin mode against fixture lcov (on x86_64 Linux and, from omni-dev 0.46.0, on ARM64 Linux, where `arm64-release-without-asset` is the control for the ARM64 legs), and in fat mode against `tests/fixtures/fat-crate/` (F5 and F6 are the `llvm-cov-ignore-filename-regex` scenarios); the `thin-mode` legs install omni-dev whenever `action.yml` or `scripts/*.sh` change, and on the weekly and manual runs (#66); the `output-flag` job checks the omni-dev floor a pull request needs; the `ignore-filename-regex` job checks the filter on the thin-mode line gate and `ignore-filename-regex-flag` the omni-dev floor for it; the `version-pin` job installs `version: v0.45.0`, and its control `0.45.0`, on a runner with a cache key that cannot hit; the `version-input` job runs an empty `version`, a lone `v` and `V0.45.0` through the action; the `deprecation-control` job logs an omni-dev deprecation warning on purpose, and asks `latest` about a flag that cannot exist, as the guard's probe does; the `latest-redirect` job resolves `version: latest` with a token the API refuses, so the redirect has to answer; the `old-glibc` job runs the pre-built binary on ubuntu-22.04, whose glibc is too old for it, with ubuntu-24.04 as its control (#67); a job asserts the failure messages the scenarios logged and that no other job logged a deprecation warning; the last, `ci-gate`, is the one check of this workflow the merge queue requires (see "Merge queue")
- `tests/job-log.sh` - Prints the log of one job of the current run, read through the Actions API (the job list and the log are each retried); `job-errors.sh`, `job-deprecations.sh` and `job-warnings.sh` pick their lines from it (`tests/job-errors.test.sh` tests all four against a fake `gh`; `test.yml` runs that)
- `tests/job-errors.sh` - Prints the `##[error]` messages one job of the current run logged
- `tests/run-jobs.sh` - Prints the jobs of the current run as one JSON array (`id`, `name`, `status`, `conclusion`), looking again at a failed call, a body that is not JSON, an empty list, a list short of the API's `total_count` and one shorter than `RUN_JOBS_MIN`; the deprecation step reads it (`tests/run-jobs.test.sh` tests it against a fake `gh` and reads `integration.yml` for the wiring; `test.yml` runs that)
- `tests/job-warnings.sh` - Prints the `##[warning]` lines one job of the current run logged, anchored on the runner's timestamp (the runner's own notices included: the caller picks the one it means; `tests/job-errors.test.sh` tests it, and reads the workflow and `action.yml` to keep the assertion's fragments and the action's warning in step)
- `tests/job-deprecations.sh` - Prints the `warning: ... deprecated` lines one job of the current run logged
- `tests/fixtures/fat-crate/` - Dependency-free crate the fat-mode integration job copies to the workspace root (never run in place); `src/ignored.rs` is the file nothing reaches, which F5 excludes and F6 keeps
- `tests/move-outputs.sh` - Moves one scenario's outputs aside between scenarios (shared by the fat-mode and PR-path jobs)
- `tests/llvm-tool-shim.sh` - Pass-through for `llvm-cov`/`llvm-profdata` that logs each `llvm-profdata merge`; the fat-mode job installs it to assert the profile is merged once (see "One profile merge"; `tests/llvm-tool-shim.test.sh` tests it, with stub tools; `test.yml` runs that)
- `.github/workflows/pr-paths.yml` - Runs the action down the paths only a pull request or a push to `main` takes: the sticky comment, baseline publish and hit, the ancestor fallback, the merge-base worktree recompute, `ignore-filename-regex` reaching the comment and the patch gate, and `llvm-cov-ignore-filename-regex` reaching the recompute's report
- `tests/write-pr-fixtures.sh` - Writes the sharded lcov fixtures and the locally committed `patch-fixture.txt` that `pr-paths.yml` runs on (`extra` adds a second patched file for P5 and P6)
- `tests/read-sticky-comment.sh` - Reads (and optionally deletes) the sticky comment for a header through the API
- `tests/fixtures/delta-crate/` - Base and head versions of a crate, committed in a job to give the merge-base recompute a base commit; `ignored.rs` is committed unchanged with both, for the filter scenario
- `.github/workflows/e2e-sharded.yml` - A real sharded run: a shard matrix (`cargo llvm-cov nextest --partition`), the artifact hand-off, and an aggregation job running the action, with the pull-request / `main` loop on top
- `tests/prepare-shard-crate.sh` - Copies the shard fixture crate to `sharded-crate/`; with `--commit`, also commits it locally (`tests/prepare-shard-crate.test.sh` tests it; `test.yml` runs that)
- `tests/assert-lib.sh` - Assertion helpers the `e2e-sharded.yml` checking steps source (`tests/assert-lib.test.sh` tests them; `test.yml` runs that)
- `tests/expected-baseline.sh` - What the baseline lookup should find for a commit, read from the Actions API through `gh` (`tests/expected-baseline.test.sh` tests it against a stub `gh`; `test.yml` runs that)
- `tests/baseline-lib.sh` - Checks of a baseline's `TN:` commit, the comment's ancestor note and the lookup against `expected-baseline.sh`, sourced by `pr-paths.yml` and `e2e-sharded.yml` (`tests/baseline-lib.test.sh` tests it, including against the real diff step; `test.yml` runs that)
- `tests/check-deprecated-flags.sh` - Fails when `action.yml` or `scripts/*.sh` passes omni-dev a deprecated flag (`tests/check-deprecated-flags.test.sh` tests it; `test.yml` runs both)
- `tests/assert-omni-dev-version.sh` - Fails unless the `omni-dev` on PATH is exactly the pinned version; the jobs that assert a scenario's outcome, in `integration.yml`, `pr-paths.yml` and `e2e-sharded.yml`, end on it (`tests/assert-omni-dev-version.test.sh` tests it; `test.yml` runs that)
- `tests/install-cache.sh` - Chooses the `cache-prefix` the `thin-mode` legs pass (a hash of `action.yml` and `scripts/*.sh` on a pull request and a push, the run and attempt on `schedule` and `workflow_dispatch`, and the leg in both) and checks the action's `omni-dev-cache-hit` output (`check` for the `thin-mode` legs, `check-fresh`, which refuses a hit on every event, for `version-pin`) (`tests/install-cache.test.sh` tests it, and reads `action.yml` and `integration.yml` for the wiring; `test.yml` runs that)
- `tests/ci-gate.sh` - What the `ci-gate` job of `integration.yml` runs: fails unless every job it needs finished `success`, from `toJSON(needs)` in `$NEEDS`
- `tests/merge-queue.test.sh` - Tests `ci-gate.sh`, and reads the workflows to check what the merge queue relies on: `ci-gate` needs every job of `integration.yml` and runs `always()`, `merge_group` is a trigger of the three workflows a required check comes from and of neither path-filtered one, and the required checks' names are still the jobs' names (`test.yml` runs that)
- `tests/fixtures/shard-crate/` - Dependency-free crate the shard jobs measure (copied to `sharded-crate/`, never run in place)
- `tests/fixtures/omni-dev-probe/` - What the real releases either side of each guard floor (and 0.28.0, which has no `coverage`) answered to the guard's probe, one `<version>/<flag>.txt` each: `exit=<status>`, then the output (`tests/guard-step.test.sh` replays them)
- `tests/fixtures/omni-dev-loader/` - What the dynamic loader printed when a pre-built omni-dev Linux binary needed a newer glibc than the runner had (Ubuntu 22.04, glibc 2.35), one `<release>-<arch>-glibc-<version>.txt` each: `exit=<status>`, then the output (`tests/print-version-step.test.sh` replays them)
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
     merged profile. Every `report` call takes `llvm-cov-ignore-filename-regex`.
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
    21 lookups per pull-request run, and none finds anything), and why the depth is a bound.
  - The recompute stays the last resort and runs only when nothing is in reach, so the
    `recompute` job of `pr-paths.yml` turns the walk off: its synthetic base has none.
- **The recompute removes its worktree (#78)**: "Compute baseline from merge-base (fallback)"
  builds at `../base` and removes it when the step ends, so a second run of the action in one job
  after a recompute finds none (it used to stop at `git worktree add` with `'../base' already
  exists`, which is what `pr-paths.yml` removed by hand between R1 and R3) and the merge-base's
  whole build (`../base/target`) does not stay on the disk for the rest of the job. Rules, so they
  are not re-derived:
  - It is an `EXIT` trap, set right after the `git worktree add` succeeds, so it covers a
    recompute that fails midway (the tests failed, `cargo` is missing) as well as one that works,
    and removes only a worktree this run made. The step's own exit status is the trap's to leave
    alone (`|| true`); a failed removal costs disk, not the run. The trap holds no variable:
    the step drops its own (`REPORT`, `TEST_ARGS`, ...) before the merge-base's tests run.
  - **A stale one is cleared before the add**: `git worktree remove --force ../base 2>/dev/null
    || true`, then `git worktree prune`. A worktree an earlier run left (cancelled before this step
    ended, on a reused runner) is registered and stops the add; so does a record whose directory
    was wiped. On git 2.50 `remove --force` clears that record itself, so no case can tell `prune`
    apart there (found in review): `prune` is kept for gits where it does not, and is held as text.
    `prune` is `|| true`, so it adds no way for a working run to fail. `remove` only touches a
    worktree git knows, so a directory that merely has the name `base` is kept, and the add then
    fails as it always did (decided: a directory of someone else's is not the action's to delete,
    and the failure says `already exists`). `prune` is repository-wide, but it drops only records
    whose directory is already gone, which no checkout of a CI workspace needs.
  - **Known limits, accepted (review):** the clear's stderr is hidden, so a leftover it could not
    remove (locked, root-owned) shows only as the add's `already exists`; a worktree of the
    caller's own registered at `../base` is removed by the clear, with its uncommitted changes (the
    run would have failed at the add before, so no working run changes); a SIGKILL during the
    removal, after the runner's INT and TERM window, can leave a half-deleted `../base` that
    neither `remove` nor `prune` clears, which is no worse than before; and a caller's cache of
    `../base` finds it gone at the end of the job. **A caller who copied the old workaround (a
    `git worktree remove --force ../base` step between two runs of the action) now fails there:
    the worktree is already gone, git exits 128 with `'../base' is not a working tree`. The README
    says to delete that step, or add `|| true`.** Rejected: removing after use only (a
    cancelled run leaves it for the next),
    and `rm -rf ../base` (it would delete that directory).
  - The removal comes after the baseline is copied: the `sed` that rewrites the report's paths
    reads `../base/<report>` first, and the step's last line is the `recomputed=true` output.
  - `tests/recompute-worktree.test.sh` runs the step with the real `git` in a throwaway repository
    and a stub `cargo`, and checks the disk: gone after a recompute and after a failing one, a
    second recompute in the same workspace writes the same baseline, a registered leftover and a
    record with no directory are cleared, a plain directory is kept (with its file) and nothing is
    run, a downloaded baseline and refused `worktree-system-deps` end before any of it, and the
    order of the lines (as text: git would refuse to remove a plain directory whichever came
    first). It fails on the old step (20 cases) and was checked against mutations: no trap (11),
    no stale clear (5), no prune (2), the trap before the add (1, the text), the removal at the end
    only (4). `input-steps.test.sh`'s stub-git cases list the three new git calls.
  - R3 of `pr-paths.yml` is the runner's test of it: the job's `Remove the worktree R1 left` step
    is gone and R3 still has to pass as the job's second recompute. Not run on a runner when this
    was written: that is the pull request's own `PR paths` run.
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
  - **The workflows are scanned too (#73)**: `test.yml` runs `bash tests/check-run-expressions.sh
    action.yml .github/workflows/*.yml .github/workflows/*.yaml` after `shopt -s nullglob`
    (GitHub reads both extensions, and without `nullglob` the empty `*.yaml` glob reaches the
    check as a file that does not exist and it exits 2), with the allowlist still empty; the
    no-argument default stays `action.yml`. Decided so it is not re-derived: the mechanism is
    the same (the runner substitutes before the shell parses), and these workflows run on
    `pull_request` and `push`, where `github.head_ref`, a pull request's title or a
    `workflow_dispatch` input in a `run:` body is a command injection. A trusted value (a
    `matrix` entry) is held to the rule too, because "no exceptions" is the rule with no list
    to keep: pass it through `env:`. All five workflows were clean when this was decided (177
    lines hold `${{`, none inside a `run:` body; the check's own report is the evidence), so it
    changed nothing but the next pull request that puts one back. Rejected: scanning with
    allowlist entries for matrix values (nothing needs one), and leaving the workflows out
    (nothing but this note would then say it was deliberate). An entry is matched on the
    step's name and the expression, not on the file, so two steps of one name in different
    files would share it: if a workflow ever needs an entry, make it name its file first.
    - The step attribution had to learn the workflows' layout. A list ahead of the steps with a
      shallower dash than theirs (`integration.yml`'s weekly `schedule:` entry, dash at column
      4, steps at column 6) used to stay "the step", so no finding in that file named one and
      an allowlist entry could never have matched there. A line that is no list item, comment
      or blank and is not indented deeper than the last list item now closes that list. Found
      in review by planting in `integration.yml`, which `pr-paths.yml` (a `paths:` list at the
      steps' own column) never showed.
    - `check-run-expressions.test.sh` plants an expression in the first `run: |` body of a
      copy of every workflow that has one and expects the line and the step named. It fails
      if `e2e-sharded.yml`, `integration.yml` or `pr-paths.yml` has none to plant in, and
      checks `test.yml` for both globs and `nullglob`. `commit-check.yml` has no `run:`, so it
      is checked as committed only.
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
    -u VERSION cargo install`, and `unset REPORT WORKTREE_SYSTEM_DEPS TEST_ARGS BASE_SHA
    LLVM_COV_IGNORE_FILENAME_REGEX` before the merge-base's `cargo llvm-cov` (the last is copied
    into the `ignore` array first, which is how the recompute's report still gets the filter).
    `tests/input-steps.test.sh` asserts it, and `tests/llvm-cov-ignore-steps.test.sh` asserts the
    filter variable.
  - The step tests set the variables and assert that each step's `env:` block fills them from
    the right place, and that the script holds no expression: setting variables alone would
    pass if `env:` were wired wrong. `tests/input-steps.test.sh` runs every other step that
    reads an input against stub `cargo`, `git`, `omni-dev` and `sudo` and asserts the
    arguments, with a canary command in each hostile value that must never run. A mutation run
    (remove each guard, unset, `set -f` or quote in a copy of `action.yml`) is how its coverage
    was checked.
  - Not covered by a unit test: the pull-request paths on a real runner (`pr-paths.yml`,
    `e2e-sharded.yml`, `integration.yml`'s fat-mode job). The download step is unit-tested
    (`download-step.test.sh`, #83: what it leaves at `~/.cargo/bin/omni-dev` for each archive
    layout; `platform-step.test.sh` covers what picks its URL), not on a real runner: its zip
    branch has never run on Windows (see the Windows zip bullet under "Pre-built asset").
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
    `move-outputs.sh` files per scenario. F1, F2, F3, F5 and F6 expect 1 (the old order
    gives 4, 4, 3, 4 and 4) and F4, which stops before any report, expects 0, so the 1s are counts.
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
  - **The Windows zip is read by name, not by glob (#82), and the step is unit-tested (#83).**
    The release zip holds `omni-dev.exe` beside `omni-dev-mcp.exe`, and the zip branch took the
    first file `find` listed for `omni-dev*`, in directory order. NTFS lists by name and
    `omni-dev-mcp.exe` sorts before `omni-dev.exe` (`-` is before `.`), so a Windows runner was
    likely to install the MCP binary as `omni-dev` (reasoned from the listing and seen on macOS,
    where it came first; no runner has run the branch). It now finds `-name omni-dev.exe` and
    installs that, still as `~/.cargo/bin/omni-dev` with no `.exe`, because that is the path the
    cache step saves and restores. With no such file it fails with one `::error::` that names the
    archive and lists what it held (sorted with `LC_ALL=C`, so the message does not depend on the
    runner's locale). The old `find | head | xargs` ran nothing for an empty result and the step
    then failed on `chmod` with a bare "No such file or directory", naming neither the archive nor
    the file; it "succeeded" only when it had installed the wrong binary. A name that only starts like the binary's
    (`omni-dev.exe.sig`) is not it. The tarball branch names its file already and is unchanged.
    Rules, so they are not re-derived:
    - `tests/download-step.test.sh` runs the step's own script against archives of the real
      layout (a few bytes each, named as the release's; the content says which file it stands
      for, so omni-dev is told from omni-dev-mcp by what was installed). It fails on the old zip
      branch (`omni-dev-mcp.exe` installed, and the zip with no binary installing it too) and
      was checked against mutations of the new one: `chmod` dropped, the name globbed again, the
      empty check dropped, the first-line cut dropped (a zip with two `omni-dev.exe` is what
      holds it), the tarball's `mv` of another file.
    - The zip cases run with a stub `find` that lists in ascending, descending (`LC_ALL=C`, so
      `-` sorts before `.`) and the filesystem's own order. Which file the old step picked
      depended on the listing, so without the stub the test would pass or fail with the
      machine it ran on.
    - **The step's fixed `/tmp` is rewritten in the script text, not made a variable.** The
      #83 options were `HOME` plus the real `/tmp`, or `${RUNNER_TEMP:-/tmp}` in the step. The
      second would change what the step does on every runner to serve a test: `version-pin`
      read the archive at `/tmp/<asset>` until #84 (it reads the `omni-dev-cache-hit` output
      now), and a Windows `runner.temp` is a backslash path nobody has run. So the test replaces
      `/tmp` with a directory of the case's own and checks that the archive (the main tarball and
      zip cases) and the extraction (both branches) landed there; that moves where the step
      writes and nothing it does. If the step ever writes somewhere else outside `HOME`, the test
      must learn it.
    - **No Windows leg, decided in #82.** Nothing here runs on Windows: the rest of the action
      (awk, `sudo`, `~`, `/tmp` in Git Bash, the fat-mode cargo steps) has never run there either,
      so a leg would be a project of its own and nobody has asked for it. The Windows install is
      covered by the unit test only, which pins the extraction and not that the result runs. Not
      verified: that a PE file named `omni-dev`, with no `.exe`, starts from bash on a Windows
      runner (Cygwin and MSYS bash run one by passing the name to the loader, which would make
      it work; nothing has shown it). If someone installs on Windows and `Print omni-dev
      version` fails, that is where to look.
  - The `0.46.0` leg is the floor for the ARM64 pre-built install and stays put, as
    `0.45.0` does for the gate; unlike `OLD_OMNI_DEV` it does not wait on anything. The
    matrix cannot read `env`, so the version is a literal and `failure-messages` repeats
    it (with the leg's job name, `Thin mode (omni-dev 0.46.0, ARM64)`: the x86_64 legs
    keep the names they had, so no lookup or required check moved).
  - The legs run on `ubuntu-24.04-arm`, not an older ARM image: omni-dev's Linux binaries,
    the x86_64 ones too, need glibc 2.39 (the highest `GLIBC_` version in each binary's
    version-needs table, read from the 0.45.0 and 0.46.0 releases), Ubuntu 24.04's (the x86_64
    0.45.0 loader reports 2.38 as the hard requirement and 2.39 as a weak one, #67), so an
    older runner image fails at `Print omni-dev version`, which now says why (#67, below). Every leg checks it ran on the
    architecture it names (`runner.arch` and `uname -m`), as job 6 does, so a leg cannot
    pass as ARM64 on another runner.
  - **The install runs when the install code changes, not only on a cache miss (decided in
    #66).** `actions/cache` restores `~/.cargo/bin/omni-dev` on a hit and "Determine platform
    and download URL" and "Download pre-built binary" are then skipped. The default key holds
    the version, not the action's code, so a leg that exists to run the install passed on a
    binary an earlier run had installed, whatever a change did to the platform step, the
    download or `scripts/omni-dev-asset.sh`. Every `thin-mode` leg (x86_64 and ARM64, pinned
    and `latest`) now passes the `cache-prefix` that `tests/install-cache.sh prefix` prints:
    `install-<16 hex of hashFiles('action.yml', 'scripts/*.sh')>-<leg>-` on `pull_request` and
    `push` (a change to the install code is a new key and installs; unchanged code reuses the
    entry, so a push to a pull request writes none), and `run-<run_id>-<run_attempt>-<leg>-`
    on `schedule` and `workflow_dispatch` (the weekly and manual runs install every time, and a
    re-run installs again). Rules:
    - Both prefixes carry the leg (`matrix.omni-dev`, through `INSTALL_CACHE_LEG`). Legs of one
      job can resolve to the same key: ARM64 pinned `0.46.0` and ARM64 `latest` do whenever
      latest is `0.46.0`. Shared, whichever finishes first saves the entry the other restores,
      and the other leg then runs no install on a change that was meant to make it: this
      happened on #77's own run, where the ARM64 `latest` leg's third and fourth scenarios
      hit the pinned leg's entry (its first two had missed). On a run-id event `check` would
      also fail a leg that did nothing wrong. The review found it for the run-id prefix; the
      run showed the hash prefix had it too. The leg costs one entry more per pair of legs that
      coincide (9-18 MB), which is the price of each leg's install not depending on a race.
    - The checking step reads the action's `omni-dev-cache-hit` output from scenario 1 (a
      failed scenario exposes no outputs, and the entry is saved in the post step, so s1 sees
      the cache as the job found it) and calls `install-cache.sh check`. It logs whether the
      install ran, logs a hit on unchanged code as correct, and FAILS a hit on `schedule` or
      `workflow_dispatch`, where the prefix is unique to the run and a hit means it never
      reached the action. It is an output because a composite action's steps are invisible to
      the workflow that calls it. `version-pin` reads the same output and calls
      `install-cache.sh check-fresh`, which fails on a hit whatever the event (#84): its
      key holds the run, the attempt and its pin, so it is unique on every event and `check`,
      whose rule depends on the event, cannot say that. It used to look for the archive the
      download step leaves in `/tmp`, a side effect of that step. `install-cache.test.sh` holds the
      mode's cases and the job's wiring (the output read, the call and its `|| status=1`, the
      key's run and attempt, no `/tmp`), each checked against a mutation that fails it.
    - The hash covers the whole of `action.yml` and `scripts/*.sh`, not just the install
      steps: a change elsewhere in `action.yml` reinstalls once, which costs seconds, and a
      list of install files kept by hand is what the ARM64-only attempt in #65 was dropped
      for. `tests/install-cache.test.sh` keeps the glob honest by reading the real files: it
      fails when an install step runs a file from `$ACTION_PATH` outside `scripts/*.sh`, when
      the workflow's `hashFiles` stops being exactly those two globs, when a `thin-mode`
      scenario does not pass the prefix, and when the prefix step is not ahead of the first
      scenario (read before it is written, the prefix is empty, which is the default key). A
      new install script goes under `scripts/`, or the globs are widened in the workflow, the
      test and `install-cache.sh` together. Each of those cases was checked against a mutation
      that makes it fail.
    - `hashFiles` gives an empty string when its globs match nothing, and a constant prefix
      would stop invalidating the cache without a word, so `prefix` refuses an empty or
      non-hex hash. The step calls it as `prefix="$(bash tests/install-cache.sh prefix)"`, not
      inside an `echo`: under `bash -e` a failure is lost there.
    - What it costs, accepted: the four scenarios of a leg each miss on the first run for a
      prefix (the entry is saved only in the post step), so omni-dev is installed four times
      and three of the four saves log `Unable to reserve cache`; and the weekly and manual runs
      write an entry per leg that nothing restores (9-18 MB, removed when unused for 7 days).
      `version-pin` removes the binary so nothing is saved; these legs do not, because the
      hashed entries are reused.
    - Settled with it, so it is not re-derived. Only the jobs whose point is the install take
      the prefix: `thin-mode-old-omni-dev`, `output-flag`, `ignore-filename-regex*`,
      `latest-redirect`, `fat-mode`, `deprecation-control`, `pr-paths.yml` and
      `e2e-sharded.yml` exist for something else and keep the cache, which is useful to them;
      `version-pin` already forces the install with a key of its own; and
      `arm64-release-without-asset` installs nothing, so its key is never saved and cannot hit.
      The `latest` legs do not cover themselves (a new release is a new key; a change to the
      install code is not). The weekly run installs on every `thin-mode` leg, pinned included.
    - Not run on a runner when this was written: the `schedule` and `workflow_dispatch`
      branches, only unit-tested, until the Monday run or a manual one. #66 left out a
      stub-`curl` test of "Download pre-built binary" with a tarball of the real layout
      (`omni-dev`, `omni-dev-mcp`, `LICENSE`, `README.md`) and one of the Windows zip's, which
      pins the extraction on every pull request whatever the cache holds, including the
      `.zip` branch no runner exercises: it is `tests/download-step.test.sh` now (#83).
  - The `latest` ARM64 leg shares the release-asset lag the other `latest` legs have, and
    may see it for longer or shorter, as the asset can be uploaded by another job than the
    x86_64 one: a red `latest` leg right after an omni-dev release, with "has no pre-built
    omni-dev-linux-arm64.tar.gz", is a re-run, not a regression.
  - **A binary that cannot start on an older glibc (#67, decided: react, and document).** On a
    runner whose glibc is older than the binary's (`ubuntu-22.04`, `ubuntu-22.04-arm`, a
    Debian 12 or Amazon Linux host) the platform step finds the asset, the download works, and
    the first failure is the dynamic loader's own message from `omni-dev --version`. "Print
    omni-dev version" now runs the binary once, keeps what it said and, when that is a missing
    `GLIBC_` version, adds one `::error::` that names the release and the platform, the glibc
    the binary needs, the glibc the runner has (`getconf GNU_LIBC_VERSION`) and the two ways out
    (a newer runner image, or `use-prebuilt-binary: 'false'`). Anything else that stops the
    binary is shown as before and keeps its exit status. Rules, so they are not re-derived:
    - **React, don't ask first.** The option of reading the runner's glibc before the download and
      comparing it with a number written into this action was rejected: that number belongs to
      omni-dev's build image and moves with it, in either direction (too high refuses a runner
      that works, too low is the problem today). The loader's message cannot go stale that way and
      cannot refuse a runner that works. It costs a download of a binary that cannot run.
    - **The glibc named is the newest NON-weak version the loader reports.** The captured output
      (`tests/fixtures/omni-dev-loader/`) shows why: the 0.45.0 x86_64 binary fails on `GLIBC_2.38`
      and also logs `weak version GLIBC_2.39`, an optional one that did not stop it, so asking for
      2.39 would name a version the run did not fail on; and the 0.46.0 ARM64 binary lists 2.39
      before 2.38, so the first line is not the answer either. They are compared as numbers
      (`sort -t. -k1,1n -k2,2n -k3,3n`; `2.9` must not beat `2.38`). `GLIBCXX_` (an old libstdc++)
      is another problem and is not matched. The message says "or newer", not that the runner will
      then work: the loader reports what it checked.
    - **It is the loader's text that is matched, so it is replayed from what the loader printed.**
      `tests/print-version-step.test.sh` runs the step against those captures and a stub `getconf`,
      and each capture is also checked for the message it is meant to hold. A new capture is a new
      file there (`exit=<status>`, then the output) and a case.
    - **The `old-glibc` job shows it on a real old image (#67): ubuntu-22.04 expects failure, and
      ubuntu-24.04 is the control with the same inputs.** The failing leg checks that it ran on
      x86_64 with a glibc below 2.38 and that the binary was installed (so this is a binary that
      cannot start, not one that was never found), that the install failed and stopped before the
      shards were combined; the control that it succeeded and that `omni-dev` is exactly 0.45.0.
      `failure-messages` asserts the message of the failing leg (the release and platform, "needs
      glibc 2.38 or newer, and the runner has glibc 2.35.", and each way out). The version is a
      literal, `0.45.0`, because the matrix cannot read `env` and because the x86_64 capture is of
      that release. It runs the install and does not restore a binary, as a job whose point is the
      install must (see the cache rule above): each leg's `cache-prefix` holds the run and the
      attempt, as `version-pin`'s does, and a last step removes the binary so no entry is saved
      that nothing would restore. If GitHub retires the `ubuntu-22.04` image the leg
      ends at the runner, not at an assertion. Both legs check out with `fetch-depth: 0`, as
      `output-flag` does: on a pull request the control goes on to "Determine merge-base", which
      needs `origin/main`, and the job's first run died there (`fatal: Not a valid object name
      origin/main`, exit 128) on a shallow clone. The failing leg stops long before that.
    - **Observed on a real runner (2026-10-04, `ubuntu-22.04` image 20260927.309.1, glibc 2.35, omni-dev
      0.45.0)**, the first time the action was seen on an older image: the loader printed exactly
      the captured text (``version `GLIBC_2.38' not found`` and the weak 2.39), the step logged
      the message with 2.38 and 2.35, and the leg's assertions held. What was inferred before that
      from #80's capture (an Ubuntu 22.04 container) is now seen on the hosted image. That run hit
      the cache, which is the path the next bullet is about.
    - **Nothing before "Print omni-dev version" may run the binary (found in review).** "Download
      pre-built binary" used to end on `~/.cargo/bin/omni-dev --version`. The download step runs
      only on a cache miss, and on a miss it ran the binary first: the loader's bare message
      failed it, the action stopped there, and the step that explains never ran. A failed job
      saves no cache, so the people this is for would have stayed on cold runs and never seen the
      message; the first CI run passed only because the `ubuntu-22.04` leg hit a cache that
      another job had saved. The line is gone, and `print-version-step.test.sh` fails if any line of
      the steps from the version to this one starts with the omni-dev command (`mv`, `chmod` and
      `cargo install omni-dev` begin with something else). The job above forces the cold path.
    - **The newer images are named only when they would do.** ubuntu-24.04 has glibc 2.39, so for
      a binary that needs more (a `GLIBC_2.40` or a `2.100`) the message asks for the glibc and
      names no image: naming 24.04 would send the caller to another failure. This is the staleness
      the rejected option 1 would have had, kept to one number in one sentence.
    - Not shown: the Windows and macOS runners (the loader's `GLIBC_` text does not exist there, so
      nothing is added and behaviour is as before), and an older runner image on ARM64 (the
      `ubuntu-22.04-arm` image would show the 2.39 case; the unit test replays its capture).
- **Version resolution (#1, #40)**: `version: latest` costs one call to the GitHub API
  (`.../repos/rust-works/omni-dev/releases/latest`), and one more request if the API gives no
  release in any attempt (the redirect fallback, below); a pinned version makes none. Made
  unauthenticated from a shared runner address it hit the 60/hr limit and failed the whole job,
  so the step sends `github-token` (default `github.token`, 1000/hr) and tries up to three times,
  sleeping 3s then 6s (none after the last) before the redirect fallback, except that a 401, 403
  or 429 is not retried (#62, below); if that fails too, one error names both failures, the input
  to check and the other way out, pinning `version`.
  Each call is bounded (`--connect-timeout 10 --max-time 30`), so a hung connection is
  retried instead of waited on until the job's timeout. Rules:
  - **A refusal is not retried (#62).** The API call asks curl for the status (`-w '\n%{http_code}'`,
    after the body; curl prints `000` for a connection that failed, and there is still no `--fail`,
    so a 403 keeps the body GitHub's reason comes from), and a 401, 403 or 429 ends the API's part
    at the first call: no wait, no `Attempt n/3` warning (it would claim retries that did not
    happen), and straight to the redirect. Retried as before, up to three times with the waits:
    no answer, a timeout, a 5xx, a 404, a body that is not JSON, JSON with no `tag_name`: what a
    retry can help. Decided so it is not re-derived: a 403 can be a rate limit or a plain refusal,
    and a secondary limit asks for a wait of a minute or more, so a 9s retry helps neither and all
    three are final; a 401 is a token that is wrong however often it is sent. It costs nothing a
    run could have used: the three attempts of a refused token spent 9.3s (3s, 6s) of the run, and
    the `latest-redirect` job (scenario 10) went from that to about a second. The step builds one
    text for what the API did, `api_gave`, that both the fallback's warning and the error start
    with: `The GitHub API gave no release after 3 attempts (API: <reason>)` after retries, and
    `The GitHub API refused the request (HTTP <status>) and was not asked again, since retrying
    cannot change that (API: <reason>)` after a refusal. A 502 and then a 401 retries once and
    stops (the warning for the 502 is `Attempt 1/3`, the refusal is named separately).
    `tests/resolve-version-step.test.sh`: the stub `curl` prints the status line the way curl does
    (`@<status>@` in a scripted response, 200 without it, `000` when curl failed), the cases that
    retried on a rate-limit body now use a 502 (a real rate limit is 403 and is final), and new
    cases pin each of 401, 403, 429 (one API call and the redirect, no wait, one warning that names
    the reason and the status and does not say `Attempt` or `3 attempts`, and the error for a
    refusal when the redirect fails too), the statuses still retried (404, 500, 502, 503, 504), a
    502 then a 401, and no token. Against the old step 70 cases fail, and each of these mutations
    fails at least one: 401, 403 or 429 left out of the refused set (22, 30, 17), a 502 or a 404
    added to it (109, 5), no `break` on a refusal or the `Attempt` warning kept (62 each), no `-w`
    (70), the refusal's text saying `3 attempts` (15), the error ignoring the refusal (6), and the
    split taking the first newline and not the last (found in review: every body in the stub was one
    line with no trailing newline, so it passed, while the real API's `...}\n` then curl's own `\n`
    gave jq a lone `{` and the step retried three times, quietly, with the redirect saving the run;
    the stub now keeps a body's trailing newline and the pretty-printed 200, 401 and CRLF 403 cases
    catch it). One mutant survives and is equivalent: not splitting the status line off the body,
    since `jq` reads the first JSON value and is silent about the number after it.
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
    `latest` branch: `VERSION="${VERSION#v}"` when it was written (now `${VERSION#[vV]}`, below). A pin
    written as a release tag (`v0.45.0`) used to give `release-tag=vv0.45.0` (a 404 that the platform
    step reports as a missing asset), its own cache key, and a `cargo install --version` that cargo
    refuses ("not a valid SemVer requirement"). Only one `v`, and only a leading one: `0.46.0-dev` keeps
    its. Keep the strip out of the `latest` branch, or a pin skips it;
    `tests/resolve-version-step.test.sh` runs both spellings and checks the input says so.
    That test reads the step alone; the `version-pin` job in `integration.yml` runs both spellings
    through the whole install on a runner (see "Integration workflow").
  - A capital `V` is dropped the same way (#51): `VERSION="${VERSION#[vV]}"`. It has one reading, and
    `release-tag` stays lowercase, as release tags are written, so `V0.45.0` shares `0.45.0`'s cache entry.
    Still one character: `vV0.45.0` and `Vv0.45.0` keep the second, visibly wrong. Accepted rather than
    rejected because rejecting adds a message and a branch to say what the strip says for free.
  - A value with nothing left after the strip (`v`, `V`, or an empty one) fails the step with one
    `::error::` that names the `version` input, quotes what it got and offers a release number or `latest`,
    before either output is written. Left to pass, the version output was empty (a cache key ending
    `--binary`) and the platform step blamed the release. The check sits after the strip and after the
    `latest` branch, so it holds however the value was obtained. The shape check below handles the rest of
    what a value may hold, but a whitespace-only value (a space is allowed there) and `Latest` are not handled.
    The script cannot say whether a workflow's `version: ''` reaches it or the input's default applies
    instead; the `version-input` job of `integration.yml` shows it on a runner.
  - **The value's shape (#72, #75)**: after the strip and the empty check, and before either output is
    written, the value must be made only of letters, digits and `. + - * ^ ~ < > =` and spaces, or the
    step fails with one `::error::` that names the input and quotes what it got, with each non-printable
    character shown as `?` and cut at 60 characters, so a newline in it cannot start another workflow
    command. It is an allowlist in a `case`, with the letters spelled out and not ranged, because a range
    follows the locale. Why: the value is written to `$GITHUB_OUTPUT`, a cache key, the download URL and
    `cargo install --version`. A newline wrote extra output lines (an input could set `release-tag`), and
    `/..` walked the URL out of `rust-works/omni-dev/releases/download/` (curl resolves dot segments, and
    five of them leave the repository). It is not a shell-injection hole (the value reaches the script
    through `env:`, #39), and `version` is normally a literal, so it matters only to a caller who passes a
    value they do not control. Decided so it is not re-derived: #72 recommended refusing only control
    characters and `/` so that `^0.45` keeps working on the source install, and #75 the strict release shape,
    which refuses a requirement. This is the allowlist in between: what a release and a cargo requirement
    are written with, and none of what changes the meaning of a value once written (`/ ? # % \ $`, quotes,
    a backtick, `; | &`, control characters, non-ASCII). No working value changed. Not taken from #75: its
    refusal of a space, because a requirement is written `>= 0.45`. It sits after the `latest` branch as the
    strip does, so an API `tag_name` is held to it too (the redirect fallback was already stricter).
    A comma is refused, though cargo takes a range with one (`>=0.45, <0.47`): the value is part of the
    "Cache omni-dev binary" key and `actions/cache` throws on a key with a comma in it (`checkKey` in the
    toolkit, read from its source and not seen on a runner), so such a range could never get past the next
    step. The review of this change found that; it is now refused here with the clearer message, and `>= 0.45`
    (a space, no comma) still passes. `checkKey` also throws on a key over 512 characters, which this step
    does not check: a value that long still fails later, at the cache step, as before.
    `tests/resolve-version-step.test.sh` has a case per refused shape (each must fail, write nothing, make
    no request and log one line) and per accepted spelling, and one loop over every character 0x01-0x7f
    that appends it to a release and asserts the step accepts exactly the 72 that the allowlist names (the
    expected set is built from character codes, not from the step's own list). Before that loop a typo in
    the 62-letter-and-digit literal, or an extra `$ : @ _ ! [ ] { } ( )`, passed the suite. It was checked
    against the check removed, `/`, `?`, `%` and `,` allowed, `^`, `+`, an uppercase letter, a lowercase
    letter, a digit and the space missing, the message not sanitised or cut short, a refusal that does not
    stop, and the stripped value quoted in place of the given one. Not run on a runner: no `integration.yml` scenario sends a hostile `version` (the
    `version-input` job sends the empty and the lone `v`).
  - The release-asset downloads stay unauthenticated on purpose. They are `github.com/.../releases/
    download/` URLs, not API calls, so the limit in #1 does not apply to them, and curl drops
    `Authorization` on the redirect to the asset CDN: the header would only send the token somewhere
    it buys nothing.
  - **Redirect fallback (#40)**: a spent limit can last up to an hour, longer than the attempts can
    wait, so when the API gives no release (after the third failure, or at once after a refusal, #62)
    the step reads the tag from the redirect of
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
      "gave no release", not that it did not answer, because a refusal is an answer (since #62 the
      refusal's own wording says it: "refused the request (HTTP 401) and was not asked again").
    - Whether github.com throttles the redirect on a runner's address is not known. It cannot make a
      run worse (the fallback runs only after the API failed), but it was not measured from a runner
      when this was written. The `latest-redirect` job is that measurement and keeps checking, weekly
      too: scenario 10 sends the token `not-a-token`, which the API refuses with 401 whatever the rate
      limit and without spending any, so its one API call fails on demand (a 401 is not retried,
      #62) and the redirect must answer; the job asks the API directly, with the workflow token, what "latest" is, and the two
      must agree. A second run of the action is not the control: with the fallback it would use the
      redirect too whenever the API failed, and a second `latest` install would break the one
      omni-dev version per job rule. The 401 is recorded just before 10 and asserted at the end,
      because a job cannot read its own log. What 10's log says is now asserted too (#61):
      `failure-messages` reads the job's `##[warning]` lines with `tests/job-warnings.sh` and
      requires ONE warning to hold the API's reason (`(API: Bad credentials)`), the redirect
      answering (`so latest omni-dev was resolved from the github.com releases/latest redirect
      instead: v`) and the way out (`set 'version' to a release to skip the lookup`). Until #62 the
      job's log held four warnings that named the API's reason (three `Attempt n/3` and the
      fallback's), so the checks hold the fallback's own words and all three must be in the same
      warning: that stays the rule, though a refused token now logs only the fallback's, worded
      `The GitHub API refused the request (HTTP 401) and was not asked again, ... (API: Bad
      credentials), so latest omni-dev was resolved ...`. A reworded warning, or the workflow token reaching 10 so that the API answers and no fallback
      is logged, fails it. That `github-token` reaches the step is still pinned only by the unit
      test.
      - The assertion's fragments are fixed strings, and the warning holds two values the runner
        fills in (the API's reason, the tag), so `job-errors.test.sh` pairs each fragment with the
        text of `action.yml`'s script for it, read from the files and not copied (the tag's `v` is
        the redirect shape check's, `Bad credentials` is what the API says to 10's token; the reason
        is paired with the `api_gave` text for a refusal, since that is the one 10 takes), and fails
        when either side is edited alone.
      - Checked by hand, not on a runner: the real resolve step run locally with
        `GH_TOKEN=not-a-token` against the live API gave exactly the four warnings #61 quotes
        (v0.46.0), and the workflow's own `expect` calls passed on them; with the fallback's wording
        changed, with no warnings, and with only the three `Attempt` lines each of the three checks
        failed. Run again for #62 it gave the one refusal warning in about a second (it was 9s),
        and the same three checks passed on it.
      - The reader only reads: a warning is not a failure, so nothing turns a job red for logging
        one, and `job-deprecations.sh` still skips `##[warning]` lines on purpose.
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
  - **The scratch directory is `work_dir` (#71)**, called once right after sourcing the
    library: it sets `$WORK` to a new `mktemp -d` and removes it on exit, whichever way the
    test ends, keeping the test's own status. Do not write `WORK="$(mktemp -d)"` and
    `trap 'rm -rf "$WORK"' EXIT` in a test again. It owns the EXIT trap, and `trap` replaces
    rather than adds: a test that needs more cleanup sets its own trap afterwards and removes
    `"$WORK"` in it too (none does today). If the directory cannot be made it ends the test,
    since an empty `$WORK` would write under `/`. Sourcing the library installs no trap, so a
    test that never calls it leaves nothing behind. `test-lib.test.sh` keeps its own
    `mktemp` and `trap` because it is what tests `work_dir`. Left alone, on purpose: the
    per-case `mktemp -d "$WORK/case.XXXXXX"` and `fresh()` functions, which differ (some also
    make `bin/` and `logs/` or write a fake `gh`), and the stubs, which are what each test is
    about. A shared helper moves nothing about what a test prints: every converted test's
    output was identical before and after (temp paths aside), which is the check to repeat if
    this changes.
  - It reads the layout `action.yml` has (a step at 4 spaces, its keys at 6, the `run: |`
    body at 8) and refuses the rest: nothing on stdout, the reason on stderr, status 1. Call it
    as `X="$(step_run 'Step name')" || exit 1`; a `-z` check on the result is not needed, and a
    fourth awk copy would read the wrong thing without saying so. `run: |`, `|-` and `|+` are
    all read; an inline `run:` (`Add cargo bin to PATH` is one), a folded `>`, a body not at
    8 spaces, a step with no `run:` and a name that is missing or doubled are refused.
  - **`step_field <step> <key>` and `step_map <step> <key>` (#74)** read a step's own key
    written on one line (`id`, `if`, `uses`, `shell`, an inline `run`) and the entries of its
    `env:` or `with:`, as written. They refuse what `step_run` refuses (an unset or unreadable
    `ACTION`; a step that is missing, doubled or at another indent) and a key the step does not
    have, `step_field` a key with no value on its line and a value that is a block scalar (`|`
    or `>`, which it would otherwise hand back as the bare indicator), `step_map` a key that has
    a value, an empty map, an entry at another indent and an entry whose value goes on to a
    deeper line. That last one is on purpose: the copy this replaced stopped at such a line
    without a word, so a later entry looked absent. A comment line inside a map is skipped at
    any indent (YAML ignores it), which is the other way a later entry could have looked absent. `action.yml` has one (the block `path:` of an upload step), so a
    test that needs that map extends the reader first. `step_map` holds its entries until it
    has read the whole map, so a refusal prints nothing. Where a call records one case per
    call, check the status where it is read (`if ! script="$(step_run "$name")"; then bad ...`);
    at the top of a file, `|| exit 1`. `map_value` (one entry out of what `step_map` printed) is
    the one reader left local, in `baseline-steps.test.sh`.
  - **A test is moved onto the libraries one file at a time, and its output must not change.**
    #74 did the last six; each printed exactly what it printed before (temp paths aside) and
    kept its case count, which is the check to repeat for the next. Two conventions came out of
    it. A helper that reads the last run's output (`has <name> <fragment>`) is named `out_has`,
    over the library's `has <name> <text> <fragment>`, so a name never means two things in a
    file (`check-run-expressions.test.sh`). And `baseline-lib.test.sh` needs `assert-lib.sh`'s
    `check` and `assert`, which is allowed because only the child shells that run the snippets
    under test source it: the shell that records the cases has `test-lib.sh`, which has no
    `check`, and the two are never in one shell.
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
    the fifteen jobs that assert a scenario's outcome end on, in `integration.yml`,
    `pr-paths.yml` and `e2e-sharded.yml`. `arm64-release-without-asset` installs nothing
    and `deprecation-control` has one install and asserts no outcome, so neither calls
    it; `old-glibc`'s failing leg installs a binary that cannot start, so only its control
    calls it. It needs the version line to start with `omni-dev <version>` and
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
  - A pin written as a release tag (#52): the `version-pin` job runs `version: v0.45.0`, and its
    control `0.45.0`, through the whole install on a runner. `tests/resolve-version-step.test.sh`
    reads the resolve step alone, so a later step that read `inputs.version` instead of the resolved
    value would leave it green while a `v0.45.0` caller hit the 404 again. Each leg asserts the
    install's outcome, `version` is `0.45.0`, `release-tag` is `v0.45.0`, and the binary on PATH.
    Rules:
    - Each leg's `cache-prefix` holds the run and the attempt, so the key cannot hit. The platform
      and download steps are skipped on a cache hit, and on the default key (the `ignore-filename-regex`
      job's `0.45.0` leg saves it, and `v0.45.0` resolves to it) every run after the first on `main`
      would hit and check only the outputs: the very path this job exists for would not run. The
      assertion step reads the action's `omni-dev-cache-hit` output and calls
      `install-cache.sh check-fresh` (#84), so a leg that stops forcing the install fails instead
      of passing. It used to check the archive the download step leaves in `/tmp`; the output
      asks the action directly, and does not depend on a side effect of one of its steps.
    - What that costs: nothing compares the two spellings' cache keys. A key built from
      `inputs.version` would make a duplicate cache entry, not a failure, and no test sees it.
    - The last step removes `~/.cargo/bin/omni-dev` so the cache's post step saves nothing: a key
      like this is never restored, and an entry of about 18 MiB per leg per run (the `0.45.0` one
      is 17.66 MiB; the repository's cache held about 200 MB in all when this was measured) would
      push out the entries the other jobs reuse. It runs after the
      assertions, which need the binary. The post step then logs `Path Validation Error: Path(s)
      specified in the action for caching do(es) not exist`, as a warning; `arm64-release-without-asset`
      logs the same on every run, having installed nothing.
    - A leg per spelling, each its own job, so the binary on PATH can only have come from that leg's
      install; `0.45.0` is the control and must give the same outputs. The existing thin-mode
      `0.45.0` leg is not the control: it differs in more than `version`, and in cache state.
    - The assertion step ends on `assert-omni-dev-version.sh "$VERSION"` with the action's `version`
      output, not the pin: a `v` pin is not a bare release number, and stripping it in the workflow
      would repeat the action's own strip instead of testing it.
    - No `use-prebuilt-binary: false` leg: it compiles omni-dev, and cargo refuses `v0.45.0` at
      argument parsing (#38). The source-install step reads the resolved `version`, which the unit
      test pins has no `v`; nothing pins that it reads that output and not `inputs.version`.
    - The job is in `failure-messages`' `needs`, so its log is read for deprecation warnings like the
      other green jobs; it asserts no message, so nothing else there names it. On a pull request it
      shows with `coverage.md` and `coverage.json` that the diffs ran.
    - Like every scenario here it passes `baseline-ancestor-depth: 0`.
- **Failure-message assertions**: a step cannot read its own job's log and a composite
  action exposes no output for a failing step, so the outcome and file checks pin
  the step order, not the text a user reads. The `failure-messages` job (`needs`
  every scenario job it reads, so it is skipped while one is red) reads their
  finished logs with `tests/job-errors.sh` and asserts the shard-pattern error
  names the pattern, the `--fail-under-lines` guard names the omni-dev it found and
  both ways out, and (on a pull request only, the one event that runs it) the
  `--output` guard names the omni-dev it found, the 0.32.0 floor and the way out, and
  the same for the `--ignore-filename-regex` guard (0.33.0 floor, both ways out); and
  that the resolve step's refusal of a `version` that names no release (#51) names the
  input, quotes what it got and offers both ways out, for the empty and the lone-`v` leg
  of the `version-input` job (on every event); and, from the `##[warning]` lines of the
  `latest-redirect` job read with `tests/job-warnings.sh` (#61), that scenario 10's fallback
  warning names the API's reason, says the redirect answered and offers pinning `version` (on
  every event; see the `latest-redirect` rules under "Version resolution").
  Match the found version as its own fragment: `omni-dev --version` can carry a
  commit and date after the number. Rules:
  - Read only the `##[error]` lines (or, for the one assertion about a warning, only the
    `##[warning]` lines). The log also echoes every step's script, which
    holds the same message text whether or not the step ran it, so grepping the whole
    log passes for the wrong reason.
  - Each check needs all its fragments in ONE message, so two errors (or two warnings) cannot
    add up.
  - `gh` 2.97 and later refuse to print an API response that holds terminal escape
    sequences, and a runner log is full of ANSI colour. `job-log.sh` passes
    `--allow-escape-sequences` when `gh api --help` lists it (an older `gh` has
    neither). Detect it from captured help, not a `| grep -q` pipe: `grep -q` can
    exit first and `pipefail` then fails the pipeline.
  - **The job list is looked at more than once, as the log is (#69).** `job-log.sh` lists
    the run's jobs inside the same retry as the log read (`JOB_LOG_ATTEMPTS` times, 6, with
    `JOB_LOG_DELAY` seconds between, 10) and tries again on a failed call, a body that is not
    JSON, and a list with NO job of the name. A name found twice fails at the first look:
    that is an ambiguity, not a list that is still filling in. Seen on run 37177411338
    (PR #56): three re-runs of this job failed on the API reads and a full re-run passed,
    never on an assertion (`gh: Server Error (HTTP 502)` twice; `0 jobs named ...` for jobs
    that had passed in an earlier attempt and were not re-run, a different few each time).
    The cause was not established. The likeliest reading is that the lookup ran in the first
    seconds of a partial re-run and saw an incomplete list; afterwards the API listed all 15
    jobs for every attempt. The retry covers that reading and was not shown to be enough: a
    list that is still short after 50 seconds fails as before. What it costs: a name that is
    wrong (a renamed job) and any failure that will not clear (a token without `actions:
    read`, no `gh` or `jq`) now fail after all the attempts, 50 seconds with the defaults, not
    at the first look. The log read always did. The message that ends a run of looks is the
    LAST look's (a list that lacked the job twice and then answered 502 reports the 502; the
    earlier looks are in the log above it), and "after N attempts" counts looks, not lists.
    `tests/job-errors.test.sh` replays each of these on a fake `gh` (502, an HTML body, JSON
    with no `jobs`, a list without the job, mixed sequences of them through
    `FAKE_JOBS_SEQ`, and the delay between looks after each kind of failed look, not only
    the empty list) and was checked against a `job-log.sh` without the retry (38 cases fail)
    and against one mutation of each rule: no retry on an empty list, an ambiguity retried,
    no wait after a failed call, `listed` never reset, jq's error not captured. Each fails
    at least one case.
  - **Re-run this job with the whole workflow, not alone** (`gh run rerun <id>`, not
    `--failed` or `--job`): that is what passed in #69, and a partial re-run is where the
    list came back short. This is the practice, not a proven fix.
  - **The deprecation step lists every job, and a short list there is the quiet failure
    (#89).** "Assert the deprecation warnings" reads the log of EVERY job that finished green,
    so the list decides what is read, and it has no name to miss: a list that came back short
    made it read fewer jobs, report each `ok`, and pass. A 502 on its one call failed it with
    no retry. `tests/run-jobs.sh` now does that listing, with `job-log.sh`'s policy
    (`JOB_LOG_ATTEMPTS`, `JOB_LOG_DELAY`, the last look's message ends it) and prints one JSON
    array of `{id, name, status, conclusion}`. Rules, so they are not re-derived:
    - It looks again at a failed call, a body that is not JSON or has no `jobs`, an empty list
      (the reading job is in the run), a list that holds fewer jobs than its own `total_count`,
      and a list shorter than `RUN_JOBS_MIN`. The step passes `RUN_JOBS_MIN` as the number of
      entries in `toJSON(needs)` plus one: every job it needs ran before it, and it is itself in
      the run. That is a LOWER bound: `needs` names jobs and not matrix legs (`thin-mode` alone is
      four), so a list short by fewer jobs than the matrices add clears it. The `total_count`
      check shows only a list that disagrees with the API's own count, which was not seen: #69's
      short lists were not examined for it. **Neither proves the list complete, and a short list
      that is consistent is read as complete.** The step's comment, the script's header and this
      note say so; do not let a later edit read it as a check. Rejected: the expected names. A
      matrix's display names come from its entries, and a list of them kept by hand is what the
      step reading "every job" was written to avoid.
    - `RUN_JOBS_MIN` unset is no minimum, and SET BUT EMPTY is refused (exit 2): the step's
      count comes from `jq 'length + 1' <<<"$NEEDS"`, which prints nothing if the `NEEDS:` env
      line is ever deleted, and reading that as "no bound" would drop the bound without a word
      (found in review). Any disagreement with `total_count` is retried, longer or shorter.
      The wiring cases pin the step's TEXT; none executes the step, so the nesting around
      `names` and the red-on-failure branch were checked by running the extracted step against
      stubs (in review), not by a test.
    - `job-log.sh` keeps its own listing, on purpose: its retry also covers a list with no job of
      the NAME, in the same loop as the failed call and the log read, and the tests that pin its
      messages and mixed sequences (`job-errors.test.sh`) would all have to move. Moving it onto
      `run-jobs.sh` is possible and was left out; the two now share the policy by convention, not
      by code.
    - `tests/run-jobs.test.sh` replays each shape on a fake `gh` that serves the pages one file
      each (502, HTML, JSON with no `jobs`, an empty list, a list short of `total_count`, mixed
      sequences, the wait between looks and none after the last, the bound with its off-by-one,
      the message of the LAST look), and reads `integration.yml` and `test.yml` for the wiring (the
      `NEEDS` env, `length + 1`, the call with the minimum, no bare `gh api --paginate`, a failed
      listing ending the step red, the test run by `test.yml`). Each rule was checked against a
      mutation that fails at least one case: no `total_count` check, no minimum, no empty-list
      check, a wait after the last look or none, extra fields kept, only the first page read, a
      failure that exits 0, the reason dropped from the final message, one attempt by default, and
      each of the step's wiring cases.
    - What it costs: a pull request's run makes one more request at most six times when the API
      is wrong, and the step keeps the 50 seconds an unclearable failure takes, as `job-log.sh`
      does. The step's new call runs on pull requests only, so a runner first exercises it on
      the checks of the pull request that adds it.
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
    found through the API (`tests/run-jobs.sh`, which retries; see #89 above for what it does
    and does not establish), so a new job or matrix leg is read without being added to a
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
  its measured 48.3% (14 of 29 lines; 27.6% without the extra command), so re-measure if the
  fixture's lines change or a toolchain attributes them differently. `src/ignored.rs` (5 of
  the 29 lines, reached by nothing) is what F5 and F6 are about: without it the fixture is at
  58.3% (14 of 24), and their gate of 53 sits between the two, so F5 passes only if the line
  gate is filtered too. `state()` there reads only `src/lib.rs`'s `DA:` records: with a second
  file in the report a line number means a different line in each, and the unfiltered one
  first read `ignored.rs`'s line 9 as `main_run`'s. Nothing but running the step against real
  output showed it, so a new file in a fixture means running its job's assertion step.
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
  - R3 runs R1 with `llvm-cov-ignore-filename-regex`, so R1 is its control: `src/ignored.rs`
    (committed unchanged in both commits, reached by nothing) is in both of R1's reports and
    must be in neither of R3's, the baseline the recompute builds in the worktree and the
    head's. They are two call sites, asserted apart: dropping the flag from the recompute's
    report alone fails only the baseline checks. R3 is the second recompute of the job: the
    recompute removes its worktree when it ends (#78, below), so R1 leaves none at `../base` and
    nothing clears it between (the job used to remove it by hand, and an action run twice in a
    job after a recompute would have stopped at `git worktree add`). `state()` there reads only
    `src/lib.rs`'s records, as in the fat-mode job.
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
  - The value goes in through `env:` and is read as `"$IGNORE_FILENAME_REGEX"`, as every
    input is since #39 (this was the first): a regex is full of `\`, `$` and quotes that
    bash reinterprets inside double quotes (`\\` becomes `\`) once it is part of the
    script text. The guard step reads it the same way.
  - It is passed as `--ignore-filename-regex=<value>`, one argument. As two, a pattern
    that starts with `-` (`-sys/`, for the `*-sys` crates) is read by clap as a flag
    and the step fails with "unexpected argument '-s'". Integration scenario 8a's first
    pattern starts with `-` so that a return to two arguments fails it.
  - It is not passed to `cargo llvm-cov`: the fat-mode line gate and the summary count
    every file unless `llvm-cov-ignore-filename-regex` (#2, next bullet) is set, and the
    README says so. The same string would mean something else to cargo-llvm-cov.
  - Commas split the patterns (omni-dev's `value_delimiter`), so a pattern cannot hold
    one (`a{1,3}` fails as an invalid regex); omni-dev ignores an empty piece. Nothing
    else separates them and nothing is trimmed: a newline or a space is part of the
    pattern, so a `|` block or `a, b` filters nothing, silently. #43 left that documented;
    **#48 decided to refuse it** (the issue's option 2, its stated preference): the step
    "Check the ignore-filename-regex value" fails, with one `::error::`, a value that holds a
    line break (`\n` or `\r`), a space or tab at either end, or one right beside a comma. Rules,
    so they are not re-derived:
    - **Refuse, do not normalise.** Normalising (newlines to commas, trimming) was rejected: it
      alters what a caller wrote, and a pattern that holds a leading or trailing space on purpose
      would change meaning. A refusal changes no pattern, so no working value changes: a value
      that excluded something before (bare commas, a space inside a pattern) still does.
    - **A separate step, first in the action**, not a part of the omni-dev flag guard: the guard
      is about what omni-dev accepts and runs after the install, and this needs no omni-dev, so
      a mistake in a workflow file fails in seconds, not after a `cargo install`. Its `if:` is the
      guard's own third need (the input set, and a diff runs: a pull request, or thin mode with
      the line gate); a fat-mode push runs no `omni-dev coverage diff`, so a value set there is not
      looked at. `input-steps.test.sh` pins the `if:` as text, and that it is the first step.
    - **A space inside a pattern is allowed** (`src/my dir/`): it is a character of the regex, not
      a separator. Only whitespace where a separator would be (an end, or beside a comma) is
      refused. `[ ]` writes a space there on purpose, and `\s` is not whitespace in the value, so
      it passes. A leading or trailing comma and `a,,b` pass: omni-dev ignores an empty piece.
    - The message names the input, what it holds, why it matters (the files would stay in the
      comment and the gates, with no warning) and the fixes (bare commas, `|-` for a YAML block,
      `[ ]`). The value is shown with what does not print replaced by `?` and cut at 60, so a line
      break in it cannot start a second workflow command (`input-steps.test.sh` asserts one line).
    - `tests/input-steps.test.sh`: each row of the issue's table and the neighbours (a trailing
      space, a space before the comma, a tab, a carriage return, CRLF), the controls that must
      pass, a value with a command substitution (data, never run), and the `if:`, the env wiring
      and the position. It fails on the old action, and each rule fails at least one case when it
      is removed (the newline rule 10, the carriage-return rule 1; the others vary with how the
      rule is cut out, so no count is kept for them: a reviewer's removals gave different
      numbers from the author's), as do spaces and not tabs, refusing any inner space, the value
      not sanitised or cut, a refusal that does not stop, the `if:` loosened and the env read
      from another input.
    - **The message says what to do, and no more** (found in review): `|-` only drops the last
      newline, so a block of several lines is still refused; the advice is one line, with bare
      commas, as a plain or quoted value, and `[ ]` for a space that is meant. The clause that
      explains a `?` appears only when the value had a character that does not print.
    - **Known limits, accepted:** `[[:space:]]` is the platform's: a non-breaking space or U+2003
      beside a comma is whitespace on macOS in a UTF-8 locale and not under C, and on a runner it
      is whatever glibc says (not tested there), so one pasted from a web page may pass and then
      exclude nothing. A pattern in `(?x)` verbose mode that ends in a space is refused, and `[ ]`
      is the wrong advice for it. "Matches no path" is loose for a piece that is only a space,
      which matches any path with a space in it.
    - **Scenarios 8c and 8d** of the `ignore-filename-regex` job are the runner's tests (both
      legs, every event). 8c is 8a's patterns with one space added beside the comma
      (`-nomatch\.txt, ^LICENSE$`), which would have made the second pattern ` ^LICENSE$`. 8d is
      8a's patterns as a YAML `|` block, the likeliest way to get it wrong: that its trailing
      newline survives `with:`, the input and the step's `env:` is what the unit test cannot show,
      since it sets the variable itself (a review could not verify it either), and a runner that
      trimmed it would turn 8d red. 8a is the control of both (only the space, or the block,
      differs). Each must fail, and no combined report may exist (`out/refused.lcov`,
      `out/refused-block.lcov`: the first step stopped it, a refusal anywhere later would leave
      one), and `failure-messages` asserts from the
      refusal's own message (8c: the input and what it holds, that the files would stay with no
      warning, and the fix; 8d: the line break named and shown as a `?`, and what a YAML block
      does). Checked by hand, not on a runner: the real step script with those values gave the
      messages, and the workflow's own `expect` calls passed on them. Not run on a runner when
      this was written: the pull request's own `Integration` run is the first.
  - The two gates differ when a filter removes everything: the patch gate passes (an
    empty patch is not an error to omni-dev, and the comment says so), the thin-mode
    line gate fails with "no executable lines". Documented in the README.
  - Tests: the `ignore-filename-regex` job (8a, a gate of 70 passes with LICENSE
    filtered out, 8b the control without the filter fails: 50% against 100%, 8c the same
    filter with a space beside the comma is refused, 8d the same as a YAML block, #48),
    `ignore-filename-regex-flag` (9: 0.32.0 is stopped by the guard on a pull request
    only, 0.33.0 is its control), `pr-paths.yml` P5 and P6 for the comment and the
    patch gate, and `tests/guard-step.test.sh` for the probe and the floor.
- **`llvm-cov-ignore-filename-regex`** (#2): the cargo-llvm-cov half of the filter, a second
  input and not `ignore-filename-regex` passed to cargo as well. The issue's comment left
  that open; decided on cargo-llvm-cov 0.9.1 with a throwaway crate, so it is not re-derived:
  - cargo-llvm-cov builds `<user>|<its default ignores>` and hands it to **LLVM's POSIX
    extended regex**, not Rust's. A pattern LLVM cannot compile (`(?i)GPU/`, `(?:a)`, a lazy
    `.*?`, an empty alternative `a||b`, an unbalanced `)`) is ignored TOGETHER WITH the
    defaults, with no error or warning: `tests/` (excluded by default) came back into the
    report. Reusing `ignore-filename-regex` would have changed the fat-mode summary and gate
    of anyone whose Rust-only pattern works today, on a minor release; an input that
    defaults to empty changes nothing for them. Rejected: a "safe subset" check that skips
    pieces (partial application), translating the comma list (`(?:...)`, the way to keep a
    piece self-contained, is what LLVM cannot read), and validating the pattern in the action
    (the only thing on the runner that compiles an LLVM regex is `llvm-cov`, which does not
    say). The README says to check the summary.
  - It also matches the ABSOLUTE path (#3 found that), takes ONE regex (the flag given
    twice is an error; join with `|`), and an empty value is an error. So the action passes
    it only when it is non-empty, verbatim, and never splits on commas (`{1,3}` is LLVM
    syntax). As `--ignore-filename-regex=<value>` (cargo-llvm-cov accepts that for a value
    that starts with `-` too), from `env:`, as `${VAR:+"--ignore-filename-regex=$VAR"}`: one
    word when set, nothing when not.
  - It goes to every `cargo llvm-cov report` (the lcov, `codecov.json`, the summary, the line
    gate, the recompute's), not to a `--no-report` run: the filter applies at report time.
    It does not change when the merge happens (see "One profile merge"). It reaches the scripts
    through `env:` like every input (#39), and the recompute copies it into an argument and
    unsets it before the merge-base's tests run, so they do not see it.
    `tests/llvm-cov-ignore-steps.test.sh` pins the argument at each of the five and scans
    every step's whole block (so an inline `run:` counts, which `step_run` would refuse) for
    `cargo llvm-cov report` calls, which must be those five, and for any other `cargo llvm-cov`
    call, which must be `show-env`, `clean` or `--no-report`: a sixth report step, a
    `cargo +nightly llvm-cov report`, a `cargo llvm-cov --lcov` or a `report` on the next line
    fails it until it takes the filter. It also pins that the five run in fat mode only (as
    text: no job sets the input in thin mode). Checked against mutations, each of which fails
    it: the flag dropped from one step (the summary, the recompute), an unquoted expansion, the
    flag and value as two arguments, the flag passed when empty, the input interpolated into a
    script, the five new-step shapes above, a summary step without its fat-mode `if:`, the flag
    on the `--no-report` build, commas turned into `|`.
  - The head lcov is also what a push to `main` publishes, so the baseline is filtered from
    then on. A baseline published before it was set is not, which is why the README says to
    set `ignore-filename-regex` too: that one filters it at diff time. The recompute runs in
    `../base`, not in the workspace, so a pattern that holds the workspace's path or the
    checkout directory's name (`myrepo/src/gpu/`, or anything anchored on it) matches the head
    and not the recomputed baseline, and the comment shows those files as removed. There is no
    cheap fix: the paths are rewritten after llvm-cov has applied the filter, and nothing here
    can evaluate an LLVM regex. It is documented, and R3 uses a fragment from inside the
    repository.
  - Fat mode only; in thin mode it is ignored, like the other fat-mode inputs, with no warning.
  - Tests: the unit test above, `integration.yml` F5 (the filter, a gate of 53) and F6 (the
    control without it, which fails at the gate) for the lcov, `codecov.json`, the summary and
    the gate, and `pr-paths.yml` R3 for the recompute.
- **Merge queue (#76)**: `main` is meant to merge through a GitHub merge queue, so a pull request is
  tested against the `main` it lands on and not the one it branched from (several touch
  `action.yml` and `integration.yml` at once). The workflow side is in the repository. The ruleset is
  not, and until it exists there is no queue: it is created in the settings, after `ci-gate` is on
  `main` (a required check can only be selected once it has run), from the payload in #76. Rules, so
  they are not re-derived:
  - **Required checks are exactly three**: `Validate Commit Messages` (`commit-check.yml`),
    `Shell scripts` (`test.yml`) and `ci-gate` (`integration.yml`). **Never require `PR paths` or
    `E2E sharded`, and never add `merge_group` to them.** They are path-filtered, so a required one
    would wait forever on a pull request that touches none of its paths, and `merge_group` has no
    `paths:` filter, so they would run unfiltered on every merge. The ruleset selects a check by its
    job's `name:`, so renaming one of the three breaks the queue silently.
  - **`merge_group:` on those three workflows** is what makes a required check report for the
    queue's commit. Without it the pull request waits forever, and nothing else shows it until the
    ruleset exists. `tests/merge-queue.test.sh` checks the trigger on the three, its absence on the
    two, and the three names.
  - **`ci-gate` is the one Integration check, not the twenty-odd job names** (a matrix change renames
    them). `failure-messages` is skipped when a scenario fails, and GitHub counts a skipped required
    check as passing, so requiring only that job would let a red pull request through. `ci-gate`
    `needs` every other job in the file, runs `if: always()` so it is red rather than skipped, and
    `tests/ci-gate.sh` reads `toJSON(needs)` from `env:` (no expression in the script, #39).
    - It is red unless every result is `success`: `skipped` and `cancelled` too. The issue said
      `failure` or `cancelled`; skipped is added on purpose. No job of `integration.yml` has an `if:`,
      so a skipped job is always downstream of a failure and this adds no red today, and a job
      skipped on purpose later turns it red with the job named, where a pass would hide it. The
      reverse hole is `continue-on-error: true` on a job, which reports a red job as `success`: so
      `tests/merge-queue.test.sh` fails on a job-level `if:` or `continue-on-error:` in any job the
      gate needs (a step-level one is fine, and the scenarios use it).
    - An empty or malformed `needs` is refused (exit 2), not passed: a gate over no jobs is how a
      deleted `needs:` would go unnoticed. It also fails closed on its own tooling: the job list is
      captured with its status checked, not read from a process substitution, because a `jq` that died
      there left a loop over nothing, which counted no failure and passed a red job (found in review;
      the test runs the script with a `jq` that dies after its first call).
    - **A new job in `integration.yml` goes in `ci-gate`'s `needs`**, or nothing waits for it.
      `tests/merge-queue.test.sh` fails until it does, and for a name in `needs` that is no job.
      Its readers are awk over the layout the file has (a block list under `needs:`, a block under
      `on:`) and refuse a flow-style one rather than read it as empty.
  - **A `merge_group` run is a `push` run that publishes no baseline.** Every event test in
    `integration.yml` and `action.yml` is `pull_request` or `push` to `main`, so the queue's commit
    gets the whole suite, the coverage and the overall line gate, and no comment, merge-base, patch
    gate or baseline publish. The uploads have no event condition and do run: `upload-artifacts`, and
    `codecov`, whose `fail_ci_if_error: true` would eject a pull request on a codecov outage. The
    README tells a caller how to turn the latter off for the event. The baseline lookup does not filter by event and looks in every
    successful run of a commit, so the `merge_group` run, which shares its head SHA with the `push`
    run that publishes the baseline, cannot hide it (the shadowing case of `tests/find-baseline.test.sh` is that shape: a newer run with no artifact in front of an older one that has it; the event itself is not exercised). Commit
    Check on the queue's ref has `GITHUB_BASE_REF` empty and a ref other than `main`, so
    omni-dev-commit-check passes no range and does not take `skip-on-main`; omni-dev lints
    `origin/main..HEAD`, and a queue-style `Merge pull request #N` commit on top of a conventional one
    linted clean locally (omni-dev 0.45.0). The concurrency groups key on `github.ref` and
    `cancel-in-progress` is for `pull_request` only, so queue runs do not cancel each other.
  - **Ruleset settings**, applied by hand on 2026-10-04 as the ruleset `main` (id 24451641, enforcement
    `active`; read or change it with `gh api repos/action-works/omni-dev-coverage-check/rulesets/24451641`
    or in the repository settings, since it is not kept in the repository) once `ci-gate` had passed
    on a `push` to `main`: merge method `MERGE`, because the baseline walk relies on
    the first-parent commits of `main` being merged pull requests, each with its own baseline;
    `max_entries_to_merge: 1` and `min_entries_to_merge: 1`, because a group of N would land as N
    first-parent commits but only one `push` run, at the tip, so N-1 would have no baseline and the
    delta would no longer be attributable to the pull request alone (expected, not verified; grouping
    buys nothing with a CI of 1 to 2 minutes); `max_entries_to_build: 5`, `grouping_strategy:
    ALLGREEN`, `check_response_timeout_minutes: 30`, `min_entries_to_merge_wait_minutes: 0`; and a
    bypass for the Repository admin role (`RepositoryRole` 5, mode `always`, which also lets an admin
    push or merge around the queue), so a red `main` can still be fixed. The required checks are the
    three above, matched by context name, with `strict_required_status_checks_policy: false` (the
    queue tests the merged result, which is what `strict` is for).
  - **Decided in #76: the `latest` jobs gate.** After each omni-dev release every `version: latest` job
    is red for about 6 to 10 minutes (#64), and `ci-gate` needs them, so a queued pull request is
    ejected in that window and has to be enqueued again. Leaving them out would mean restructuring
    `failure-messages` and `ci-gate`; #64 is the real fix. The same goes for anything else that reads
    live state: `latest-redirect`, and `deprecation-control` (an omni-dev that removes `--format` or
    rewords clap's message turns it red with no pull request at fault). Merges then wait for the
    cause to be fixed, or for the admin bypass, which is what it is for. Each merge also runs Test,
    Commit Check and Integration a second time, about 2 minutes of latency, and the cache entries a
    queue ref saves are never restored by anyone (a queue entry has its own ref), so each merge adds a
    few that age out.
  - **Verified**: plan eligibility. The `merge_queue` rule was accepted on 2026-10-04 for this public
    repository, owned by an organization on the Free plan. It is not available for a repository owned
    by a personal account, so moving the repository would end the queue.
  - **Not verified** as of 2026-10-04 (the result of the first pull request through the queue is
    recorded on #76): whether `allow_auto_merge: false` affects `gh pr merge` entering the queue (the
    setting is `false` and was not changed); that a group of N lands as N first-parent commits (the
    group size is 1, so it does not arise); and how the queue behaves on an ejection.
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
