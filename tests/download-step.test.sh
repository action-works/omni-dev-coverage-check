#!/usr/bin/env bash
# Tests the actual download step with nested patchcov release archives.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="$ROOT/action.yml"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=test-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib.sh"
work_dir
# shellcheck source-path=SCRIPTDIR
# shellcheck source=step-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/step-lib.sh"

DOWNLOAD="$(step_run 'Download pre-built binary')" || exit 1

# The step needs unzip, and the test builds the zip with python3: a runner without either
# would fail every case for a reason that is not the step's, so say so once.
command -v tar >/dev/null || { echo 'tar is required' >&2; exit 1; }

BIN="$WORK/bin"
mkdir "$BIN"
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$CURL_LOG"
out=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; fi
  shift
done
cp "$FAKE_ARCHIVE" "$out"
EOF
cat >"$BIN/find" <<'EOF'
#!/usr/bin/env bash
real="$(PATH=/usr/bin:/bin command -v find)"
case "${FIND_ORDER:-}" in
  asc) "$real" "$@" | LC_ALL=C sort ;;
  desc) "$real" "$@" | LC_ALL=C sort -r ;;
  *) exec "$real" "$@" ;;
esac
EOF
chmod +x "$BIN/curl" "$BIN/find"

# make_tar <archive> <file>...: a .tar.gz of files that each say which one they stand for,
# written 0644 so that the step's chmod is what makes the result executable.
make_tar() {
  local dest=$1 stage name
  shift
  stage="$(mktemp -d "$WORK/stage.XXXXXX")"
  for name in "$@"; do
    mkdir -p "$stage/$(dirname "$name")"
    printf 'fake %s\n' "${name##*/}" >"$stage/$name"
  done
  tar -czf "$dest" -C "$stage" "$@"
}

URL_BASE="https://github.com/rust-works/patchcov/releases/download/v0.1.1"

# run_step <archive> <asset name> [find order]: runs the step as the runner would, with
# the variables its `env:` block fills set to the values given, in a directory of its own.
# Sets CASE (that directory), STATUS (the step's exit status), STEP_OUT (what it printed),
# INSTALLED (the file the step is meant to leave) and CURLS (the curl calls it made).
run_step() {
  local archive=$1 asset=$2 order=${3:-} script
  CASE="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$CASE/home" "$CASE/tmp"
  INSTALLED="$CASE/home/.cargo/bin/patchcov"
  script="${DOWNLOAD//\/tmp/$CASE/tmp}"
  # The rewrite must have taken: the script as written is not the one that is run.
  if [ "$script" = "$DOWNLOAD" ]; then
    bad "the step's /tmp is pointed at the case's directory" "the script holds no /tmp to rewrite"
    exit 1
  fi
  # A locale that is not C: `sort` is case-insensitive in it, so the list in the error
  # (README.md before patchcov-mcp.exe, or after) is only the same everywhere if the step
  # sorts as C does. Where the locale is not installed bash falls back to C and warns.
  HOME="$CASE/home" PATH="$BIN:$PATH" LC_ALL=en_US.UTF-8 \
    DOWNLOAD_URL="$URL_BASE/$asset" BINARY_NAME="$asset" \
    FAKE_ARCHIVE="$archive" CURL_LOG="$CASE/curl.log" FIND_ORDER="$order" \
    bash --noprofile --norc -eo pipefail -c "$script" >"$CASE/out" 2>&1
  STATUS=$?
  STEP_OUT="$(cat "$CASE/out")"
  CURLS="$(cat "$CASE/curl.log" 2>/dev/null || true)"
}

# installed_files: what is in ~/.cargo/bin after the step, one name per line.
installed_files() {
  ls -A "$CASE/home/.cargo/bin" 2>/dev/null || true
}

# expect_installed <label> <content>: the step succeeded and left exactly one file, at the
# path the cache step saves, with that content and executable.
expect_installed() {
  eq "$1: the step succeeds" 0 "$STATUS"
  eq "$1: the only file installed is patchcov" patchcov "$(installed_files)"
  eq "$1: it is the right file" "$2" "$(cat "$INSTALLED" 2>/dev/null || true)"
  if [ -x "$INSTALLED" ]; then ok "$1: it is executable"; else bad "$1: it is executable" "$INSTALLED is not"; fi
}

# Releases contain exactly one tag/target directory, not a binary at the root.
for target in x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu x86_64-apple-darwin aarch64-apple-darwin; do
  asset="patchcov-v0.1.1-$target.tar.gz"
  folder="${asset%.tar.gz}"
  make_tar "$WORK/$asset" "$folder/LICENSE" "$folder/README.md" "$folder/patchcov"
  run_step "$WORK/$asset" "$asset"
  expect_installed "$target tarball" "fake patchcov"
  has "$target: the requested URL is downloaded" "$CURLS" "$URL_BASE/$asset"
  has "$target: reports installation" "$STEP_OUT" "Successfully installed patchcov"
done

asset=patchcov-v0.1.1-x86_64-unknown-linux-gnu.tar.gz
for wrong in patchcov "${asset%.tar.gz}/patchcov.bak" other/patchcov; do
  make_tar "$WORK/missing.tar.gz" "$wrong"
  run_step "$WORK/missing.tar.gz" "$asset"
  eq "$wrong: fails rather than installing a lookalike" 1 "$STATUS"
  eq "$wrong: leaves no binary" "" "$(installed_files)"
  has "$wrong: names the missing binary" "$STEP_OUT" "$asset has no ${asset%.tar.gz}/patchcov in it"
done
# Failure downloading an archive cannot install a leftover binary.
run_step "$WORK/not-present.tar.gz" "$asset"
pass "download failure propagates" test "$STATUS" -ne 0
# shellcheck disable=SC2016
eq "script: no expression" "" "$(grep -n -F '${{' <<<"$DOWNLOAD" || true)"
summary
