# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitHub Action that runs code-coverage analysis and posts a diff/patch-coverage pull-request comment using the [omni-dev](https://github.com/rust-works/omni-dev) CLI tool. It is the coverage counterpart to [action-works/omni-dev-commit-check](https://github.com/action-works/omni-dev-commit-check) and reuses that action's omni-dev install + cache pattern verbatim.

## Repository Structure

- `action.yml` - The composite GitHub Action definition (the core of this project)
- `README.md` - User documentation with examples and input/output reference
- `scripts/combine-shards.sh` - Checks and joins per-shard lcov files for the `shard-reports` input
- `tests/combine-shards.test.sh` - Plain-bash tests for that script (`.github/workflows/test.yml` runs them)
- `.omni-dev/` - Project guidelines for commits and PRs
- `.github/workflows/commit-check.yml` - Dogfoods the commit-check action on this repo
- `.github/workflows/integration.yml` - Runs the action itself (`uses: ./`) in thin mode against fixture lcov, and in fat mode against `tests/fixtures/fat-crate/`
- `tests/fixtures/fat-crate/` - Dependency-free crate the fat-mode integration job copies to the workspace root (never run in place)
- `tests/move-outputs.sh` - Moves one scenario's outputs aside between scenarios (shared by the fat-mode and PR-path jobs)
- `.github/workflows/pr-paths.yml` - Runs the action down the paths only a pull request or a push to `main` takes: the sticky comment, baseline publish and hit, and the merge-base worktree recompute
- `tests/write-pr-fixtures.sh` - Writes the sharded lcov fixtures and the locally committed `patch-fixture.txt` that `pr-paths.yml` runs on
- `tests/read-sticky-comment.sh` - Reads (and optionally deletes) the sticky comment for a header through the API
- `tests/fixtures/delta-crate/` - Base and head versions of a crate, committed in a job to give the merge-base recompute a base commit
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
     of instrumented dependency artifacts), then emit `codecov.json`, the
     per-line `report` lcov, and a `--summary-only` summary.
   - **Thin mode (`run-coverage: false`)**: skip cargo-llvm-cov entirely; the
     caller supplies the per-line lcov via the `report` input — or, for a run
     sharded across jobs, via `shard-reports`, which `scripts/combine-shards.sh`
     checks and joins into `report` so every later step still reads one file.
   - On pull requests: compute the `origin/main`..`HEAD` merge-base, download the
     `coverage-baseline` artifact for that exact commit, and on a miss recompute
     it in a git worktree (fat mode). Render the comment with
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
- **Baseline is pinned to the merge-base**, not "latest main", so per-file
  deltas are attributable to the PR alone.
- **`worktree-system-deps`** generalizes the one omni-dev-specific wrinkle from
  the original inline job (installing `libasound2-dev` before building old
  history); it installs nothing unless set.
- **`setup-commands` / `extra-test-commands`** let a caller whose coverage corpus
  isn't a single `cargo test` run still use fat mode (e.g. omni-voice: download a
  Whisper model, then run `--ignored` model-gated suites). `setup-commands` runs
  pre-test with `LLVM_PROFILE_FILE=/dev/null` (reuses the instrumented build,
  contributes no coverage); `extra-test-commands` runs post-test and DOES
  contribute. Both are skipped in the worktree recompute, so the merge-base stays
  buildable at old fork points and only `test-args` defines that baseline.
- **Shard join**: `cargo llvm-cov` writes no newline after its final `end_of_record`,
  so a bare `cat` of shards glues records and a consumer can silently drop a file.
  `combine-shards.sh` always puts a newline between shards; keep that if you touch it.
- **Thin-mode line gate needs a new omni-dev**: `latest` can resolve to a release
  without `coverage diff --fail-under-lines`, so a guard step feature-detects it and
  fails with the fix. Do not tag a release of this action until an omni-dev release
  with the flag exists, or every thin-mode caller on the default gate would fail.
- **Integration workflow**: `integration.yml` asserts each scenario's step `outcome`
  (not `conclusion`, which is `success` under `continue-on-error`). Three rules keep it
  honest. Run one omni-dev version per job: `actions/cache` saves in a post step, so a
  second version installed over `~/.cargo/bin/omni-dev` poisons the first version's
  key. Give every expected failure a control that differs in one input and must
  succeed, plus a file check showing where the action stopped. `OLD_OMNI_DEV` is the
  newest release without `--fail-under-lines`, so it stays put when the `0.45.0`
  floor rises; change it only if the guard starts detecting a newer flag.
- **Fat-mode integration job**: the action runs cargo at the workspace root and a
  caller cannot give a composite action's steps a working directory, so the job
  copies the fixture crate there (it refuses to run if a root `Cargo.toml` or `src/`
  exists). It sets `recompute-baseline: false`: the fixture is not in git history,
  so the merge-base worktree a pull request builds would have no `Cargo.toml`
  (`pr-paths.yml` covers the recompute with a crate it commits itself). The
  action writes `codecov.json`, `coverage-summary.txt` and `coverage.md` to fixed
  names, so `tests/move-outputs.sh` moves each scenario's outputs to `out/<id>/`
  before the next runs; add any new fixed-name output to its list. The fixture's
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
    producing. The last step asks the Actions API what the lookup should find (`hit`,
    `miss`, or `either` while a run is in progress) and the observed result must
    match, so both paths are tested whichever one a run takes. On a hit the baseline's
    `TN:` must be the merge-base SHA and the totals are recomputed from the downloaded
    file, so the assertions survive edits to the fixture. Expectations marked `#5`
    are the ones the nearest-ancestor fallback will change.
  - The diff is `merge-base..HEAD`, so a pull request's own changes would decide the
    patch gate. `write-pr-fixtures.sh` commits a 10-line `patch-fixture.txt` locally
    (never pushed) so the patch always has known added lines, and instruments
    `LICENSE` as the file whose coverage flips with no change to its lines (an indirect
    change, shown only with `all-files: true`). It must not be edited by a pull request.
  - Scenarios P1, P2 and P3 post under one header and render the same comment on a
    miss, so each is read back and deleted before the next. Otherwise a scenario that
    stopped posting would pass on the previous one's comment.
  - The recompute needs a commit that holds a crate, which the pull request's history
    does not, so the job commits `delta-crate`'s base and head itself and passes the
    first as `base-ref`. Its numbers are then the job's own. Unlike the fat-mode crate
    its tests need only `cargo test`, because the recompute replays only `test-args`.
  - The hit path cannot be shown before a baseline exists on `main`: the pull request
    that adds this workflow shows the miss path, the `push` run after it shows the
    publish, and the first later qualifying pull request shows the hit.
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
