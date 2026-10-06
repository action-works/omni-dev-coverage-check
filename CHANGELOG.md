# Changelog

## Unreleased — v2 (breaking)

- Run coverage diffs and gates with patchcov, with a default pin of 0.1.1.
- Install versioned Linux and macOS x64/ARM64 archives or `cargo install patchcov`;
  isolate the patchcov cache. Windows has no pre-built asset. Linux binaries require
  glibc 2.35 or newer.
- Rename `omni-dev-cache-hit` to `patchcov-cache-hit`. Generic `version` and
  `release-tag` outputs now identify patchcov; existing omni-dev pins must be replaced.
- Remove obsolete omni-dev flag-floor guards and source-install audio dependencies.
- Warn about ignored legacy coverage config, environment and tracked source markers.

Before adopting v2, migrate `.omni-dev/coverage.yaml` to `.patchcov/config.yaml`,
`OMNI_DEV_CONFIG_DIR` to `PATCHCOV_CONFIG_DIR`, and `omni-dev: coverage` markers to
`patchcov: coverage`. See [README migration instructions](README.md#migrating-from-v1-to-v2).
The repository name and coverage pipeline inputs remain the same. No compatibility
aliases or dual-tool mode are provided. This PR does not publish or move release tags.
