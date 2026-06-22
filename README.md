# Omni-Dev Coverage Check Action

A GitHub Action that runs code-coverage analysis and posts a diff/patch-coverage pull-request comment using [omni-dev](https://github.com/rust-works/omni-dev).

It is the coverage counterpart to [omni-dev-commit-check](https://github.com/action-works/omni-dev-commit-check) and reuses that action's `omni-dev` install + cache pattern (resolve version → `actions/cache@v4` → pre-built binary download with `cargo install` fallback), so the two actions stay consistent and version-pinnable.

## Features

- Cached, version-pinnable `omni-dev` binary (same key scheme as commit-check)
- **Fat mode (default)**: runs `cargo-llvm-cov` for you and produces the report
- **Thin mode**: bring your own lcov; the action only diffs, comments, and gates
- Merge-base baseline with a download + git-worktree-recompute fallback
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

### Thin mode

`run-coverage: false` skips `cargo-llvm-cov` entirely. Produce the per-line lcov
yourself (any tool, any language) and point `report` at it; the action only runs
`omni-dev coverage diff`, posts the comment, and applies `--fail-under-patch`.
The line gate and the worktree baseline fallback (both `cargo-llvm-cov`-specific)
are skipped in this mode.

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

| Input                 | Description                                                                     | Default  |
|-----------------------|---------------------------------------------------------------------------------|----------|
| `version`             | omni-dev version to install (e.g. `0.15.0`, `latest`)                           | `latest` |
| `use-prebuilt-binary` | Download a pre-built release binary instead of `cargo install` from source      | `true`   |
| `cache-prefix`        | Prefix prepended to the omni-dev binary cache key                               | `''`     |

### Coverage run (fat mode)

| Input              | Description                                                                                   | Default               |
|--------------------|-----------------------------------------------------------------------------------------------|-----------------------|
| `run-coverage`        | Run `cargo-llvm-cov` to produce the head report. Set `false` for thin mode                 | `true`                |
| `report`              | Path to the per-line head lcov (produced in fat mode, supplied in thin mode)               | `coverage-head.lcov`  |
| `test-args`           | Arguments passed to `cargo test` / `cargo llvm-cov` under instrumentation                  | `--all-features --workspace` |
| `setup-commands`      | Commands run under instrumentation BEFORE the test run, with profiling disabled (no coverage). Fetch fixtures the tests need (e.g. an ML model). One per line | `''` |
| `extra-test-commands` | Extra instrumented `cargo test` invocations run AFTER the main run, contributing coverage. For `--ignored`/model-gated suites `test-args` can't reach. One per line | `''` |
| `fail-under-lines`    | Overall line-coverage gate (`cargo llvm-cov report --fail-under-lines`). Empty disables it | `30`                  |

### Diff / patch-coverage comment

| Input              | Description                                                                          | Default      |
|--------------------|--------------------------------------------------------------------------------------|--------------|
| `base-ref`         | Base revision to diff against. Empty computes `git merge-base origin/main HEAD`       | `''`         |
| `fail-under-patch` | Patch-coverage gate (`--fail-under-patch`). Empty disables it. Enforced after comment | `''`         |
| `collapse-ranges`  | Collapse consecutive uncovered new lines into ranges (e.g. `9-11`)                    | `true`       |
| `all-files`        | Report deltas/indirect changes for ALL files, not just the diff's files              | `false`      |
| `strip-prefix`     | Override the path prefix stripped from report paths to make them repo-relative        | `''`         |
| `report-format`    | `auto`, `lcov`, `llvm-cov-json`, or `cobertura` (auto-detected when empty)            | `''`         |
| `comment`          | Post the rendered diff as a sticky PR comment                                         | `true`       |
| `comment-header`   | Sticky comment header (lets the comment update in place each run)                     | `coverage`   |

### Merge-base baseline

| Input                    | Description                                                                                     | Default            |
|--------------------------|-------------------------------------------------------------------------------------------------|--------------------|
| `baseline-artifact-name` | Name of the artifact holding the per-line baseline report                                      | `coverage-baseline`|
| `baseline-workflow`      | Workflow file the baseline artifact is published from (for the merge-base download)            | `ci.yml`           |
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
| `codecov`       | Upload `codecov.json` to codecov.io                  | `false` |
| `codecov-token` | codecov.io upload token (pass `${{ secrets.* }}`)    | `''`    |

## Outputs

| Output          | Description                                             |
|-----------------|---------------------------------------------------------|
| `version`       | Resolved omni-dev version that was installed            |
| `release-tag`   | Resolved omni-dev release tag (v-prefixed)              |
| `patch-percent` | Patch (diff) coverage percentage for this PR            |
| `line-percent`  | Overall line coverage percentage (requires a baseline)  |
| `comment-path`  | Path to the rendered markdown comment                   |

## How the baseline works

On a pull request the action pins the comparison to the PR's fork point
(`git merge-base origin/main HEAD`), an immutable commit, so per-file deltas are
attributable to *this* PR alone rather than to whatever else merged into `main`
while the PR was open:

1. **Download** the `coverage-baseline` artifact published by the `main` run for
   that exact merge-base commit (`dawidd6/action-download-artifact`). A miss is a
   warning, not a failure.
2. **Recompute fallback** (fat mode): on a miss, build coverage at the merge-base
   in a git worktree and rewrite its absolute `SF:` paths to the workspace prefix
   so `omni-dev coverage diff` strips one prefix for both head and baseline. Use
   `worktree-system-deps` if building that historical commit needs system
   packages (omni-dev passes `libasound2-dev`).
3. **Publish** on `main` pushes: this run's lcov becomes the baseline future PRs
   download.

Without a baseline the comment still renders patch coverage and the uncovered-line
list; only the deltas and indirect-change sections are omitted.

## Gates

Both gates run **last**, after the summary and PR comment, so the feedback still
posts when a gate fails:

- **Patch coverage** — set `fail-under-patch` to fail the build when the lines
  this PR added fall below the threshold.
- **Overall line coverage** — `fail-under-lines` (default `30`, fat mode) fails
  the build via `cargo llvm-cov report --fail-under-lines`.

## Requirements

- Check out with `fetch-depth: 0` so `git merge-base` can resolve the PR's fork point.
- `permissions: pull-requests: write` on the job, so the comment can be posted.
- Fat mode builds Rust under `cargo-llvm-cov`; thin mode needs only a per-line lcov.

## Example: pinned version, codecov upload, and a patch gate

```yaml
- uses: action-works/omni-dev-coverage-check@v1
  with:
    version: 0.15.0
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
