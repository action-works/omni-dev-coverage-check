# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitHub Action that runs code-coverage analysis and posts a diff/patch-coverage pull-request comment using the [omni-dev](https://github.com/rust-works/omni-dev) CLI tool. It is the coverage counterpart to [action-works/omni-dev-commit-check](https://github.com/action-works/omni-dev-commit-check) and reuses that action's omni-dev install + cache pattern verbatim.

## Repository Structure

- `action.yml` - The composite GitHub Action definition (the core of this project)
- `README.md` - User documentation with examples and input/output reference
- `scripts/combine-shards.sh` - Checks and joins per-shard lcov files for the `shard-reports` input
- `scripts/omni-dev-asset.sh` - Maps a runner's OS and architecture to the omni-dev release asset to download (`tests/omni-dev-asset.test.sh` tests it; `test.yml` runs that)
- `tests/platform-step.test.sh` - Runs the "Determine platform and download URL" and "Fail if binary not available" scripts read out of `action.yml` against a stub `curl` (`test.yml` runs that)
- `tests/combine-shards.test.sh` - Plain-bash tests for that script (`.github/workflows/test.yml` runs them)
- `.omni-dev/` - Project guidelines for commits and PRs
- `.github/workflows/commit-check.yml` - Dogfoods the commit-check action on this repo
- `.github/workflows/integration.yml` - Runs the action itself (`uses: ./`) in thin mode against fixture lcov, and in fat mode against `tests/fixtures/fat-crate/`; the `output-flag` job checks the omni-dev floor a pull request needs; the `deprecation-control` job logs an omni-dev deprecation warning on purpose; a last job asserts the failure messages the scenarios logged and that no other job logged a deprecation warning
- `tests/job-log.sh` - Prints the log of one job of the current run, read through the Actions API; `job-errors.sh` and `job-deprecations.sh` pick their lines from it (`tests/job-errors.test.sh` tests all three against a fake `gh`; `test.yml` runs that)
- `tests/job-errors.sh` - Prints the `##[error]` messages one job of the current run logged
- `tests/job-deprecations.sh` - Prints the `warning: ... deprecated` lines one job of the current run logged
- `tests/fixtures/fat-crate/` - Dependency-free crate the fat-mode integration job copies to the workspace root (never run in place)
- `tests/move-outputs.sh` - Moves one scenario's outputs aside between scenarios (shared by the fat-mode and PR-path jobs)
- `.github/workflows/pr-paths.yml` - Runs the action down the paths only a pull request or a push to `main` takes: the sticky comment, baseline publish and hit, and the merge-base worktree recompute
- `tests/write-pr-fixtures.sh` - Writes the sharded lcov fixtures and the locally committed `patch-fixture.txt` that `pr-paths.yml` runs on
- `tests/read-sticky-comment.sh` - Reads (and optionally deletes) the sticky comment for a header through the API
- `tests/fixtures/delta-crate/` - Base and head versions of a crate, committed in a job to give the merge-base recompute a base commit
- `.github/workflows/e2e-sharded.yml` - A real sharded run: a shard matrix (`cargo llvm-cov nextest --partition`), the artifact hand-off, and an aggregation job running the action, with the pull-request / `main` loop on top
- `tests/prepare-shard-crate.sh` - Copies the shard fixture crate to `sharded-crate/`; with `--commit`, also commits it locally (`tests/prepare-shard-crate.test.sh` tests it; `test.yml` runs that)
- `tests/assert-lib.sh` - Assertion helpers the `e2e-sharded.yml` checking steps source (`tests/assert-lib.test.sh` tests them; `test.yml` runs that)
- `tests/check-deprecated-flags.sh` - Fails when `action.yml` or `scripts/*.sh` passes omni-dev a deprecated flag (`tests/check-deprecated-flags.test.sh` tests it; `test.yml` runs both)
- `tests/assert-omni-dev-version.sh` - Fails unless the `omni-dev` on PATH is exactly the pinned version; the jobs that run the action in `integration.yml`, `pr-paths.yml` and `e2e-sharded.yml` end on it (`tests/assert-omni-dev-version.test.sh` tests it; `test.yml` runs that)
- `tests/fixtures/shard-crate/` - Dependency-free crate the shard jobs measure (copied to `sharded-crate/`, never run in place)
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
  never gets an ARM64 asset), with 5b as its control. The ARM64 install that succeeds
  needs a release carrying the asset (#20), and until then nothing checks the ARM64 asset's
  name against a real release.
- **No first-class shard mode (decided in #24)**: there is no `mode: shard` / `mode: report`,
  and none should be built until a real adopter has a sharded workflow on this action and
  names what was awkward. The README's sharded example, kept honest by `e2e-sharded.yml`, is
  the supported shape. The reasoning, so it is not re-derived:
  - A composite action cannot own the matrix, the artifact hand-off or the `needs`, so a
    mode would be two invocations in jobs the caller still writes, saving the shard job's
    install and partition steps (about 10 lines per shard job).
  - A reusable workflow has fixed inputs, where real callers need per-architecture setup and
    steps around the action (succinctly's x86_64 leg reclaims disk first; its ARM64 leg builds
    omni-dev from source, `use-prebuilt-binary: false`). A local `uses: ./` inside one resolves
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
- **Flags that need a new omni-dev**: one guard step captures `omni-dev coverage diff
  --help` once and feature-detects each flag the run needs, failing with the fix
  rather than letting clap report an unknown argument later. It runs before the
  coverage run, and only when a flag is needed (a fat-mode push calls no `omni-dev
  coverage`, so an old pin must keep working there). It reports every missing flag.
  - `--fail-under-lines` (0.45.0): thin mode with the line gate on. `latest` can
    resolve to a release without it. Do not tag a release of this action until an
    omni-dev release with the flag exists, or every thin-mode caller on the default
    gate would fail.
  - `--output` (0.32.0): every `pull_request`, fat or thin, because the comment diff
    runs even with `comment: false`, so no input turns this one off. 0.32.0 is the
    floor for the whole pull-request path, not just `-o` (0.29.0 to 0.31.0 have
    `--format`, and the path passes no flag 0.32.0 lacks). Probe the help text, never
    the version: the guard must keep working when `latest` moves.
  - The help capture ends in `|| true`: an omni-dev below 0.29.0 (0.28.0 is the newest)
    has no `coverage` subcommand, so `coverage diff --help` exits 2 and `-e` would end
    the step with clap's bare error before either message. A failing `--help` counts as
    "none of these flags are here", and the message still names the omni-dev found, read
    by the separate `--version` call. That is safe because `Print omni-dev version` has
    already proved the binary runs. Leave stderr unredirected: a failure that is not "no
    such subcommand" then still shows what omni-dev said, and it can only appear beside
    an error (the `if:` guarantees a flag is needed, so an empty help fails the step).
    Keep the capture tolerant if you touch it; the 0.28.0 leg below is what fails when
    it is not.
- **Integration workflow**: `integration.yml` asserts each scenario's step `outcome`
  (not `conclusion`, which is `success` under `continue-on-error`). Three rules keep it
  honest. Run one omni-dev version per job: `actions/cache` saves in a post step, so a
  second version installed over `~/.cargo/bin/omni-dev` poisons the first version's
  key. Give every expected failure a control that differs in one input and must
  succeed, plus a file check showing where the action stopped. `OLD_OMNI_DEV` is the
  newest release without `--fail-under-lines`, so it stays put when the `0.45.0`
  floor rises; change it only if the guard starts detecting a newer flag.
  - The poisoned-cache rule is checked by `tests/assert-omni-dev-version.sh <version>`, which
    the jobs that run the action end on, in `integration.yml`, `pr-paths.yml` and
    `e2e-sharded.yml`. It needs the version line to start with `omni-dev <version>` and
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
  `--output` guard names the omni-dev it found, the 0.32.0 floor and the way out.
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
    `output-flag` legs without the flag. Renaming a job or changing the matrix fails
    it loudly (no job of that name); a new matrix leg is not checked until it is
    added to the list.
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
    (update `job-deprecations.sh`) or removed the flag (retire the control).
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
    change, shown only with `all-files: true`); the head fixtures fail fast if a pull
    request edits it. The job is skipped for forks and Dependabot, whose tokens cannot
    write the comment.
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
- **E2E sharded workflow** (`e2e-sharded.yml`): the real topology the README describes
  (shard jobs → `coverage-shard-N` artifacts → an aggregation job with `pattern` +
  `merge-multiple` → the action); `pr-paths.yml` covers the same loop on hand-written
  lcov. It follows `pr-paths.yml`'s rules (push unfiltered, pull request path-filtered,
  never a required check, per-SHA concurrency on pushes, the baseline lookup asserted
  against the Actions API, the `#5` marks). What is particular to it:
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
