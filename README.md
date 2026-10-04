# Omni-Dev Coverage Check Action

A GitHub Action that runs code-coverage analysis and posts a diff/patch-coverage pull-request comment using [omni-dev](https://github.com/rust-works/omni-dev).

It is the coverage counterpart to [omni-dev-commit-check](https://github.com/action-works/omni-dev-commit-check) and reuses that action's `omni-dev` install + cache pattern (resolve version → `actions/cache@v4` → pre-built binary download with `cargo install` fallback), so the two actions stay consistent and version-pinnable.

## Features

- Cached, version-pinnable `omni-dev` binary (same key scheme as commit-check)
- **Fat mode (default)**: runs `cargo-llvm-cov` for you and produces the report
- **Thin mode**: bring your own lcov; the action only diffs, comments, and gates
- **Sharded runs**: split the instrumented run across concurrent jobs, then combine the
  shard reports in one aggregation job and keep the comment, baseline, and gates
- Merge-base baseline, falling back to the nearest ancestor's baseline and then to a
  git-worktree recompute
- Sticky pull-request comment with patch coverage, per-file deltas, and the
  uncovered `file:line` list (via `omni-dev coverage diff`)
- Full per-file summary appended to the run's Summary tab and uploaded as an artifact
- Overall line-coverage and patch-coverage gates (run *after* the comment posts)
- Optional codecov.io upload

## Quick Start

A drop-in coverage job for a Rust workspace:

```yaml
name: Coverage
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  coverage:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write        # required to post the coverage comment
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # full history so `git merge-base` resolves the fork point

      - uses: action-works/omni-dev-coverage-check@v1
```

That single step installs `omni-dev`, runs `cargo-llvm-cov`, posts the PR comment, publishes the baseline on `main`, and enforces `--fail-under-lines 30`.

## Modes

### Fat mode (default)

`run-coverage: true` (the default) makes the action run the whole `cargo-llvm-cov`
pipeline itself — exactly like a hand-rolled coverage job. You only check out the
repo with `fetch-depth: 0`; the action handles the toolchain, `cargo-llvm-cov`
install, instrumented test run, report generation, baseline, comment, and gates.

The instrumented run's raw profiles (`*.profraw`) are merged **once**, however many
outputs are produced. `cargo llvm-cov report` merges every raw profile each time it is
called, which costs minutes per call for a suite that spawns many processes and leaves
thousands of them. The action merges them with the first report (the lcov), removes the
raw profiles, and lets the `codecov.json`, summary and line-gate calls read the merged
profile. The outputs are unchanged. Once the action has run, the target directory
that `cargo llvm-cov show-env` reports (the action's steps run under it) holds the
merged profile (`<workspace-name>.profdata`) and no `*.profraw`. If a step of yours
then runs more instrumented tests under the same `show-env` and calls `cargo llvm-cov
report`, that report covers only those new runs, because this run's raw profiles are
gone.

### Thin mode

`run-coverage: false` skips `cargo-llvm-cov` entirely. Produce the per-line lcov
yourself (any tool, any language) and point `report` at it; the action runs
`omni-dev coverage diff`, posts the comment, and applies `--fail-under-patch` and
`--fail-under-lines`. The worktree baseline fallback is `cargo-llvm-cov`-specific
and is skipped in this mode, so a baseline-download miss means a comment without
deltas.

The thin-mode line gate reads the lcov itself (`omni-dev coverage diff
--fail-under-lines`) rather than `cargo llvm-cov report`, so its figure can differ
slightly from llvm-cov's own summary: on omni-dev's own suite (about 97% covered)
it ran 0.16 percentage points higher. It also needs an omni-dev release that has
the flag; the action stops with that message if the installed one does not. Set
`fail-under-lines: ''` to run thin mode without a line gate.

```yaml
- run: |
    # produce coverage-head.lcov however you like
    cargo llvm-cov --all-features --workspace --lcov --output-path coverage-head.lcov

- uses: action-works/omni-dev-coverage-check@v1
  with:
    run-coverage: false
    report: coverage-head.lcov
    fail-under-patch: 80
```

### Sharded runs (thin mode)

When the instrumented test run is too slow for one job, split it across a matrix of
shard jobs and combine their lcov reports in one aggregation job. The aggregation
job keeps everything a single job gave you: the PR comment, the baseline publish on
`main`, the patch gate, and the overall line gate.

```yaml
jobs:
  shard:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false              # a failed shard must still fail the aggregation job, not hide it
      matrix:
        shard: [1, 2, 3]
    steps:
      - uses: actions/checkout@v7
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: llvm-tools-preview
      - uses: Swatinem/rust-cache@v2
      - uses: taiki-e/install-action@v2
        with:
          tool: cargo-llvm-cov,cargo-nextest
      # `cargo test` cannot partition; nextest can.
      - run: >-
          cargo llvm-cov nextest --all-features --workspace
          --partition count:${{ matrix.shard }}/3
          --lcov --output-path shard-${{ matrix.shard }}.lcov
      - uses: actions/upload-artifact@v7
        with:
          name: coverage-shard-${{ matrix.shard }}
          path: shard-${{ matrix.shard }}.lcov

  coverage:
    needs: shard                    # not `if: always()`: a failed shard fails this job
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: actions/download-artifact@v8
        with:
          pattern: coverage-shard-*
          merge-multiple: true      # every shard file lands in one directory
          path: shards
      - uses: action-works/omni-dev-coverage-check@v1
        with:
          run-coverage: false
          shard-reports: shards/shard-*.lcov
          fail-under-lines: 70
          fail-under-patch: 80
```

The same topology (a shard matrix, `merge-multiple`, one aggregation job) runs end to
end on real runners in this repository: see
[`.github/workflows/e2e-sharded.yml`](.github/workflows/e2e-sharded.yml).

`shard-reports` takes paths or globs, one per line. The action checks each shard,
joins them into `report` (default `coverage-head.lcov`), and every later step reads
that one file, exactly as if a single job had produced it. A shard that is missing
(a glob that matches nothing, or a path that does not exist), empty, or without any
line records fails the run **by name**, so a failed shard cannot quietly lower
coverage. A shard whose absolute paths all fall outside the workspace root draws a
warning.

Things to know:

- **Partitioning needs nextest**, which the action never runs for you: the shard job
  and its `--partition count:N/M` are yours (see [Why there is no `mode: shard`](#why-there-is-no-mode-shard)).
  nextest does not run doctests, so coverage that only a doctest provides is lost
  unless you add the [doctest job](#recovering-doctest-coverage) below.
- **`setup-commands` and `extra-test-commands` are fat-mode inputs**, so a sharded
  run does that work itself, in the job that needs it. Setup that tests need (a model
  download, say) goes in each shard job that runs them. Work that should run exactly
  once rather than per shard, such as a gated `--ignored` suite, gets a job of its
  own, like the doctest job below. Three rules for such a job:
  - Name its artifact and file so the aggregation job's `pattern` and `shard-reports`
    globs match them (`coverage-shard-*` and `shard-*.lcov` above). A report the globs
    miss is not an error, because the other shards still match: coverage just drops.
  - Run it on every event the shard jobs run on. If it is skipped on pull requests
    (secrets missing on forks, say), the head report lacks lines the `main` baseline
    has, and the comment shows a drop that no change caused.
  - Run it under the same workspace root as the shards (next bullet).

  Anything nextest can partition just takes its flags on the partitioned run
  (`--run-ignored all` adds the ignored tests to a partitioned run).
- **Every shard must run under the same workspace root** (the same runner image
  does), because the report paths are made repo-relative by stripping one prefix.
  Use `strip-prefix` if the root is not the checkout directory.
- **The shards are merged as lcov.** The merge is a union: a line any shard covered is
  covered. It does not sum hit counts, which nothing in the line output reads.
- **A sharded total is not bit-identical to an unsharded one** when tests depend on
  timing or process-global state; on omni-dev's suite 38 of 324,274 lines differed.
- **`strip-prefix`, `report-format`, and the baseline are as in thin mode.**
  `report-format`, if set, must be `lcov`. The baseline published on `main` is the
  combined file.
- With `codecov: true` in thin mode, the action uploads the shard files themselves
  (codecov merges several uploads natively) and, outside sharded runs, the lcov at
  `report`, since there is no `codecov.json`.

#### Recovering doctest coverage

Add one job that runs only the doctests and uploads its own report. The join takes
any number of files, so the `coverage-shard-*` and `shards/shard-*.lcov` patterns above
pick it up unchanged; the only edit to the aggregation job is `needs: [shard, doctests]`.

```yaml
  doctests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      # `cargo llvm-cov --doc` is unstable, so this job needs nightly.
      - uses: dtolnay/rust-toolchain@nightly
        with:
          components: llvm-tools-preview   # without it cargo-llvm-cov stops at an install prompt
      - uses: Swatinem/rust-cache@v2
      - uses: taiki-e/install-action@cargo-llvm-cov
      - run: >-
          cargo llvm-cov --doc --all-features --workspace
          --lcov --output-path shard-doctests.lcov
      - uses: actions/upload-artifact@v7
        with:
          name: coverage-shard-doctests
          path: shard-doctests.lcov
```

The doctest report lists every function in the crate, mostly with a zero count. The
join is a union, so a line the shards covered stays covered. This job runs on nightly
and the shards on stable, so the two can instrument slightly different lines of a
file; a line only one report lists is counted by that report alone, and the total
can differ a little from an all-stable run.

This job is not part of `e2e-sharded.yml`. It was checked once, locally: on a copy of
that workflow's fixture crate with one doctest added, the nextest shards alone gave
87.50% and adding this report gave 100.00%.

#### Why there is no `mode: shard`

The action has no `mode: shard` / `mode: report`. A composite action cannot own the
job matrix, the artifact hand-off, or the dependency between jobs, so such a mode
would still be two invocations inside jobs you write; it would save only the shard
job's install and partition steps. The example above is the supported shape, and
[`e2e-sharded.yml`](.github/workflows/e2e-sharded.yml) runs its shard topology. The
full reasoning, and what would change it, is in
[#24](https://github.com/action-works/omni-dev-coverage-check/issues/24).

### Fat mode with fixture setup + model-gated tests

When part of your coverage comes from suites the default `test-args` run can't
reach — `--ignored` tests that need an ML model on disk, say — keep fat mode and
add two hooks. `setup-commands` runs first under the same instrumentation env but
with profiling disabled (so a model download reuses the instrumented build yet
adds no coverage); `extra-test-commands` runs the gated suites after the main
run, and their coverage lands in the head report and the line gate:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.cache/my-model            # model is cached across runs
    key: my-model-v1

- uses: action-works/omni-dev-coverage-check@v1
  with:
    setup-commands: cargo run --bin my-tool -- install-model
    extra-test-commands: |
      cargo test --all-features --test gated_inference_test -- --ignored
      cargo test --all-features --lib backends:: -- --ignored
```

The merge-base worktree recompute runs only `test-args`, not these hooks (the
gated suites/fixtures may not exist at an old fork point), and the normal path
downloads a baseline that already includes their coverage.

## Inputs

### omni-dev install + cache

| Input                 | Description                                                                                             | Default               |
|-----------------------|--------------------------------------------------------------------------------------------------------|-----------------------|
| `version`             | omni-dev version to install (e.g. `0.45.0`, `v0.45.0`, `latest`)                                       | `latest`              |
| `github-token`        | Token authenticating the GitHub API call that resolves `version: latest` (1000/hr vs 60/hr unauthed)   | `${{ github.token }}` |
| `use-prebuilt-binary` | Download a pre-built release binary instead of `cargo install` from source                             | `true`                |
| `cache-prefix`        | Prefix prepended to the omni-dev binary cache key                                                       | `''`                  |

`version: latest` makes one call to the GitHub API to find the newest release. It sends `github-token` and tries
three times (waiting 3s, then 6s) before the step fails, so the 60-requests-an-hour limit on unauthenticated calls
from a shared runner address does not fail the job. It needs no configuration: the token defaults to the workflow's.
A pinned `version` makes no API call, and may be written as a release tag is, with a leading `v`: `v0.45.0` and
`0.45.0` give the same `version` (`0.45.0`) and `release-tag` (`v0.45.0`) outputs and share one cache entry.

The pre-built binary is chosen from the runner's OS and architecture: Linux x64, macOS ARM64 and Windows today,
and Linux ARM64 from the first omni-dev release that publishes `omni-dev-linux-arm64.tar.gz` (built since
[rust-works/omni-dev#2116](https://github.com/rust-works/omni-dev/issues/2116)). Until then an ARM64 Linux runner
on the default `use-prebuilt-binary: 'true'` fails at the install step. So does a platform with no pre-built binary
(macOS x64, a 32-bit Linux runner). The message names the platform or the missing asset: set
`use-prebuilt-binary: 'false'` to build omni-dev from source instead, or `version` to a release that has the asset.

### Coverage run (fat mode)

| Input              | Description                                                                                   | Default               |
|--------------------|-----------------------------------------------------------------------------------------------|-----------------------|
| `run-coverage`        | Run `cargo-llvm-cov` to produce the head report. Set `false` for thin mode                 | `true`                |
| `report`              | Path to the per-line head lcov (produced in fat mode, supplied in thin mode; with `shard-reports`, where the combined report is written) | `coverage-head.lcov`  |
| `shard-reports`       | Thin mode: the per-shard lcov reports (paths or globs, one per line) to check and combine into `report`. Requires `run-coverage: false` | `''` |
| `test-args`           | Arguments passed to `cargo test` / `cargo llvm-cov` under instrumentation                  | `--all-features --workspace` |
| `setup-commands`      | Commands run under instrumentation BEFORE the test run, with profiling disabled (no coverage). Fetch fixtures the tests need (e.g. an ML model). One per line | `''` |
| `extra-test-commands` | Extra instrumented `cargo test` invocations run AFTER the main run, contributing coverage. For `--ignored`/model-gated suites `test-args` can't reach. One per line | `''` |
| `fail-under-lines`    | Overall line-coverage gate: `cargo llvm-cov report --fail-under-lines` in fat mode, `omni-dev coverage diff --fail-under-lines` in thin mode (needs an omni-dev release with the flag). Empty disables it | `30`                  |

### Diff / patch-coverage comment

| Input              | Description                                                                          | Default      |
|--------------------|--------------------------------------------------------------------------------------|--------------|
| `base-ref`         | Base revision to diff against. Empty computes `git merge-base origin/main HEAD`       | `''`         |
| `fail-under-patch` | Patch-coverage gate (`--fail-under-patch`). Empty disables it. Enforced after comment | `''`         |
| `collapse-ranges`  | Collapse consecutive uncovered new lines into ranges (e.g. `9-11`)                    | `true`       |
| `all-files`        | Report deltas/indirect changes for ALL files, not just the diff's files              | `false`      |
| `strip-prefix`     | Override the path prefix stripped from report paths to make them repo-relative        | `''`         |
| `ignore-filename-regex` | Exclude files whose repo-relative path matches any of these regexes (comma-separated) from the head and baseline reports before the diff. [Details](#excluding-files-ci-cannot-measure) | `''` |
| `report-format`    | `auto`, `lcov`, `llvm-cov-json`, or `cobertura` (auto-detected when empty)            | `''`         |
| `comment`          | Post the rendered diff as a sticky PR comment                                         | `true`       |
| `comment-header`   | Sticky comment header (lets the comment update in place each run)                     | `coverage`   |

### Merge-base baseline

| Input                    | Description                                                                                     | Default            |
|--------------------------|-------------------------------------------------------------------------------------------------|--------------------|
| `baseline-artifact-name` | Name of the artifact holding the per-line baseline report                                      | `coverage-baseline`|
| `baseline-workflow`      | Workflow file the baseline artifact is published from (for the merge-base download). One that does not exist yet is a miss with a warning, not a failure | `ci.yml` |
| `baseline-ancestor-depth` | When the merge-base has no baseline, how many of its first-parent ancestors to try, nearest first, before giving up. `0` uses the merge-base's own only | `10`               |
| `recompute-baseline`     | On a download miss, recompute coverage at the merge-base in a git worktree (fat mode only)     | `true`             |
| `worktree-system-deps`   | Space-separated apt packages to install before the worktree recompute (e.g. `libasound2-dev`)  | `''`               |
| `publish-baseline`       | On a push to `main`, publish this run's report as the baseline artifact                        | `true`             |

### Artifacts

| Input              | Description                                                  | Default            |
|--------------------|--------------------------------------------------------------|--------------------|
| `upload-artifacts` | Upload the summary / report / codecov.json as a build artifact | `true`           |
| `artifact-name`    | Name of the uploaded coverage-summary artifact               | `coverage-summary` |

### codecov.io upload

| Input           | Description                                          | Default |
|-----------------|------------------------------------------------------|---------|
| `codecov`       | Upload to codecov.io: `codecov.json` in fat mode, the lcov (the shard files when sharded) in thin mode | `false` |
| `codecov-token` | codecov.io upload token (pass `${{ secrets.* }}`)    | `''`    |

## Outputs

| Output          | Description                                             |
|-----------------|---------------------------------------------------------|
| `version`       | Resolved omni-dev version installed (no leading `v`)    |
| `release-tag`   | Resolved omni-dev release tag (v-prefixed)              |
| `patch-percent` | Patch (diff) coverage percentage for this PR            |
| `line-percent`  | Overall line coverage percentage (requires a baseline)  |
| `comment-path`  | Path to the rendered markdown comment                   |

## How the baseline works

On a pull request the action pins the comparison to the PR's fork point
(`git merge-base origin/main HEAD`), an immutable commit, so per-file deltas are
attributable to *this* PR alone rather than to whatever else merged into `main`
while the PR was open:

1. **Find** the `coverage-baseline` artifact published by the `main` run for that
   exact merge-base commit. If the merge-base has none, try its first-parent
   ancestors, nearest first, up to `baseline-ancestor-depth` of them, and use the
   first baseline found. A miss is a warning, not a failure.
2. **Download** it (`dawidd6/action-download-artifact`, by the run that was found).
3. **Recompute fallback** (fat mode): when nothing is in reach, build coverage at the
   merge-base in a git worktree and rewrite its absolute `SF:` paths to the workspace
   prefix so `omni-dev coverage diff` strips one prefix for both head and baseline.
   Use `worktree-system-deps` if building that historical commit needs system
   packages (omni-dev passes `libasound2-dev`).
4. **Publish** on `main` pushes: this run's lcov becomes the baseline future PRs
   download. In a sharded run that is the combined report.

Without a baseline the comment still renders patch coverage and the uncovered-line
list; only the deltas and indirect-change sections are omitted.

### What counts as a baseline

A commit has one when a **successful** run of `baseline-workflow` for it, in this
repository, holds an **unexpired** artifact named `baseline-artifact-name`. Every such
run is looked in, not only the newest, so a run that has no artifact (the
`merge_group` run of a merge queue, which shares its head SHA with the `push` run that
publishes) cannot hide the run that has it. Runs from forks are ignored.

- **Only first parents are walked.** On `main` those are the merged pull requests, each of
  which published a baseline; a second parent is a pull request's own branch, which did
  not. A shallow checkout gives a shorter walk, which is why `fetch-depth: 0` is
  required.
- **A baseline workflow that does not exist is a miss.** The API knows a workflow only
  once its file is on the default branch, so pointing `baseline-workflow` at a new
  workflow before it has merged logs a warning and carries on, instead of failing the
  step. Any other API failure (a permission, an outage) still fails the step with its
  status and message, because it says nothing about whether a baseline exists.
- **A run that is still in progress is not used**, even if it has already uploaded the
  artifact. If the `push` run for the merge-base has not finished, the next ancestor's
  baseline is used instead of rebuilding.
- **Cost.** Each commit tried costs at least one GitHub API request, plus one for each
  successful run it has, so a lookup that finds nothing spends `baseline-ancestor-depth + 1`.
  On github.com the workflow token allows 1,000 requests an hour per repository.

### When the baseline is an ancestor's

The deltas then compare this pull request with a baseline from a few commits before its
fork point, so they also include whatever those commits changed (usually small, and the
diff already tolerates drift). The patch is unaffected: it is still `merge-base..HEAD`.
The comment says so, on its last line:

> _Baseline: the report published for [`abc1234`](…), 2 commits before the merge-base,
> which has none. The deltas also include whatever those commits changed._

Set `baseline-ancestor-depth: 0` for the exact-merge-base lookup: a merge-base with no
baseline is then a miss, and in fat mode it is recomputed.

## Gates

Both gates run **last**, after the summary and PR comment, so the feedback still
posts when a gate fails:

- **Patch coverage** — set `fail-under-patch` to fail the build when the lines
  this PR added fall below the threshold.
- **Overall line coverage** — `fail-under-lines` (default `30`) fails the build.
  Fat mode uses `cargo llvm-cov report --fail-under-lines`; thin mode uses
  `omni-dev coverage diff --fail-under-lines`, which counts from the lcov and can
  differ slightly from llvm-cov's figure. Thin mode gates on every event, a push
  included. **If you used thin mode before this input applied to it, the default
  now gates you at 30%;** set `fail-under-lines: ''` to keep the old behaviour.

## Excluding files CI cannot measure

Code a CI runner cannot execute (a GPU path, a backend gated to one platform) shows
near-zero coverage and reads as a regression in the comment. `ignore-filename-regex`
drops those files from the diff instead:

```yaml
- uses: action-works/omni-dev-coverage-check@v1
  with:
    ignore-filename-regex: 'src/voice/backends/voxtral_mlx/,src/gpu/'
```

- The value is a list of regexes on one line, separated by commas, each matched against
  a file's repo-relative path (after `strip-prefix`) and unanchored, so `src/gpu/`
  excludes everything under it. Only a comma separates patterns: a newline or a space is
  part of a pattern, so a `|` block (which ends in a newline) or `a, b` (which looks for
  ` b`) excludes nothing, and a pattern cannot contain a comma (`a{1,3}` is split in two
  and fails as an invalid regex). An empty piece (`a,,b`, a trailing comma) is ignored,
  so a typo cannot exclude everything.
- The path is repo-relative, where `cargo llvm-cov --ignore-filename-regex` matches the
  absolute one: a pattern written there, such as `^/home/runner/work/…/gpu/`, matches
  nothing here, with no warning, and `^src/` written here would match nothing there.
- The files are dropped from the head **and** the baseline report before anything is
  computed, so the total, the per-file deltas, the patch coverage and the indirect
  changes all describe the same files, even when the baseline was published before the
  exclusion.
- The comment, the patch gate and the thin-mode line gate all get the filter, so a gated
  percentage is the one the comment shows, and so do the `patch-percent` and
  `line-percent` outputs, which are read from the same diff.
- A filter that removes everything is not an error, and the gates differ: if it removes
  every line a pull request adds, the patch gate has nothing to measure and passes, and
  the comment says "No new executable lines added by this diff"; if it removes every
  line of the report, the thin-mode line gate fails with "no executable lines". Check
  the comment when a pattern is broad.
- It does not reach what `cargo-llvm-cov` computes: in fat mode the `fail-under-lines`
  gate and the coverage summary still count every file. Nor does it change the baseline
  artifact (published as the raw report) or the codecov upload.
- It needs omni-dev 0.33.0 or later; see [Requirements](#requirements).

## Requirements

- Check out with `fetch-depth: 0` so `git merge-base` can resolve the PR's fork point and
  the baseline lookup can walk its ancestors.
- `permissions: pull-requests: write` on the job, so the comment can be posted.
- Fat mode builds Rust under `cargo-llvm-cov`; thin mode needs only a per-line lcov.
- Thin mode's line gate and `shard-reports` need an omni-dev release that has
  `coverage diff --fail-under-lines` (the first after v0.44.0). With `version: latest`
  that is automatic once it is released; if you pin `version`, pin one that has it.
- The pull-request comment, the patch gate and the thin-mode line gate pass
  `-o/--output` to `omni-dev coverage diff`, which needs omni-dev 0.32.0 or later (its
  predecessor `--format` is deprecated and due to be removed in a future major). With
  `version: latest` that is automatic; if you pin `version`, pin 0.32.0 or later. On a
  pull request, in either mode, an older omni-dev stops the action before the coverage
  run with a message that names the version it found and the 0.32.0 floor, rather than
  clap's bare `unexpected argument '-o'` from the comment step. That includes an
  omni-dev below 0.29.0, which has no `coverage` subcommand at all. Other events are
  unaffected.
- `ignore-filename-regex` needs omni-dev 0.33.0 or later, the first release with
  `coverage diff --ignore-filename-regex`. With `version: latest` that is automatic; if
  you pin `version`, pin 0.33.0 or later. With the input set, an older omni-dev stops the
  action before the coverage run, with a message that names the version it found and the
  0.33.0 floor, on a pull request and in thin mode with the line gate on: the two places
  a diff runs. A fat-mode push runs none, so it is unaffected. The input empty asks
  nothing of omni-dev.

## Example: pinned version, codecov upload, and a patch gate

```yaml
- uses: action-works/omni-dev-coverage-check@v1
  with:
    version: 0.45.0
    fail-under-lines: 60
    fail-under-patch: 80
    worktree-system-deps: libasound2-dev
    codecov: true
    codecov-token: ${{ secrets.CODECOV_TOKEN }}
```

## CircleCI

A CircleCI counterpart (mirroring commit-check's `omni-dev-commit-check-cci`) is
not part of this repository yet; track it separately if you need one.

## License

MIT
