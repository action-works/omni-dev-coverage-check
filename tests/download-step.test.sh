#!/usr/bin/env bash
# Tests for the "Download pre-built binary" step of action.yml (#83, #82). Plain bash, no
# framework:
#   tests/download-step.test.sh
# Exits non-zero if any case fails.
#
# tests/platform-step.test.sh covers what chooses the URL; this covers what the step does
# with the archive it downloads: which file ends up at ~/.cargo/bin/omni-dev. It runs the
# step's own script, read out of action.yml, against archives with the layout of the real
# release assets (v0.46.0, from `tar -tzf` and `unzip -l`):
#
#   omni-dev-linux.tar.gz    LICENSE, README.md, omni-dev, omni-dev-mcp
#   omni-dev-windows.zip     LICENSE, omni-dev-mcp.exe, omni-dev.exe, README.md
#
# The files are a few bytes each, named as the release's are; the real binaries are tens
# of MB and must not be committed. A file's content says which file it stands for, so a
# case can tell omni-dev from omni-dev-mcp by what was installed and not only by its name.
#
# The step writes to a fixed /tmp and to ~/.cargo/bin, and a test that let it would write
# there on a developer's machine. HOME is a directory of the case's own, and every /tmp in
# the script text is rewritten to a directory of the case's own too (the script is checked
# to hold one, so the rewrite is not a no-op, and each case checks the archive landed in
# its own directory). That changes where the step writes and nothing it does.
#
# `curl` is a stub that copies the archive the case built to the path after -o, and logs
# its arguments. `find` is a stub that runs the real one and lists what it found in the
# order the case asks for (ascending, descending, or as the filesystem gives it): the
# order `find` lists a directory in is the filesystem's, so without it a test of "whatever
# order the archive's files are listed in" would pass or fail with the machine it ran on.

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
for tool in unzip python3 tar; do
  command -v "$tool" >/dev/null || {
    echo "$tool is needed to run this test and was not found on PATH" >&2
    exit 1
  }
done

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
    printf 'fake %s\n' "$name" >"$stage/$name"
  done
  tar -czf "$dest" -C "$stage" "$@"
}

# make_zip <archive> <path>...: a .zip with those entries (a path may hold a directory). A
# file in it says which one it stands for by its own name, and has no executable bit, as a
# zip made on Windows has none.
make_zip() {
  python3 - "$@" <<'PY'
import sys, zipfile
dest, *names = sys.argv[1:]
with zipfile.ZipFile(dest, "w") as z:
    for name in names:
        z.writestr(name, "fake %s\n" % name.rsplit("/", 1)[-1])
PY
}

URL_BASE="https://github.com/rust-works/omni-dev/releases/download/v0.46.0"

# run_step <archive> <asset name> [find order]: runs the step as the runner would, with
# the variables its `env:` block fills set to the values given, in a directory of its own.
# Sets CASE (that directory), STATUS (the step's exit status), STEP_OUT (what it printed),
# INSTALLED (the file the step is meant to leave) and CURLS (the curl calls it made).
run_step() {
  local archive=$1 asset=$2 order=${3:-} script
  CASE="$(mktemp -d "$WORK/case.XXXXXX")"
  mkdir "$CASE/home" "$CASE/tmp"
  INSTALLED="$CASE/home/.cargo/bin/omni-dev"
  script="${DOWNLOAD//\/tmp/$CASE/tmp}"
  # The rewrite must have taken: the script as written is not the one that is run.
  if [ "$script" = "$DOWNLOAD" ]; then
    bad "the step's /tmp is pointed at the case's directory" "the script holds no /tmp to rewrite"
    exit 1
  fi
  # A locale that is not C: `sort` is case-insensitive in it, so the list in the error
  # (README.md before omni-dev-mcp.exe, or after) is only the same everywhere if the step
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
  eq "$1: the only file installed is omni-dev" omni-dev "$(installed_files)"
  eq "$1: it is the right file" "$2" "$(cat "$INSTALLED" 2>/dev/null || true)"
  if [ -x "$INSTALLED" ]; then ok "$1: it is executable"; else bad "$1: it is executable" "$INSTALLED is not"; fi
}

# --- the Linux and macOS tarball: omni-dev beside omni-dev-mcp --------------------------

make_tar "$WORK/linux.tar.gz" LICENSE README.md omni-dev omni-dev-mcp
run_step "$WORK/linux.tar.gz" omni-dev-linux.tar.gz
expect_installed "tarball" "fake omni-dev"
has "tarball: it downloads the URL it was given" "$CURLS" "$URL_BASE/omni-dev-linux.tar.gz"
has "tarball: it saves the archive where it was told" "$CURLS" "-o $CASE/tmp/omni-dev-linux.tar.gz"
has "tarball: it says it installed" "$STEP_OUT" "Successfully installed omni-dev from pre-built binary"
# `tar -C /tmp` extracts omni-dev-mcp, LICENSE and README.md beside omni-dev; only omni-dev is moved.
if [ -f "$CASE/tmp/omni-dev-mcp" ]; then ok "tarball: it extracts into the case's own directory"; else bad "tarball: it extracts into the case's own directory" "no $CASE/tmp/omni-dev-mcp"; fi

# omni-dev-mcp first in the archive: the tarball branch names its file, so no order matters.
make_tar "$WORK/linux-mcp-first.tar.gz" omni-dev-mcp LICENSE README.md omni-dev
run_step "$WORK/linux-mcp-first.tar.gz" omni-dev-linux.tar.gz
expect_installed "tarball, omni-dev-mcp listed first" "fake omni-dev"

make_tar "$WORK/linux-no-binary.tar.gz" LICENSE README.md omni-dev-mcp
run_step "$WORK/linux-no-binary.tar.gz" omni-dev-linux.tar.gz
if [ "$STATUS" -ne 0 ]; then ok "tarball without omni-dev: the step fails"; else bad "tarball without omni-dev: the step fails" "it succeeded"; fi
eq "tarball without omni-dev: nothing is installed" "" "$(installed_files)"

# --- the Windows zip: omni-dev.exe beside omni-dev-mcp.exe (#82) -----------------------

make_zip "$WORK/windows.zip" LICENSE omni-dev-mcp.exe omni-dev.exe README.md
# `find` lists a directory in the filesystem's order, which is not defined, so each order
# is asked for. The bug: `-name "omni-dev*"` with `head -1` kept omni-dev-mcp.exe when it
# came first, which is the ascending one (`-` sorts before `.`).
for order in asc desc ""; do
  label="zip, find lists ${order:-as the filesystem does}"
  run_step "$WORK/windows.zip" omni-dev-windows.zip "$order"
  expect_installed "$label" "fake omni-dev.exe"
  has "$label: it saves the archive where it was told" "$CURLS" "-o $CASE/tmp/omni-dev-windows.zip"
done

# A zip whose binary sits in a directory is still found (the step did not need the layout
# to be flat, and still does not).
make_zip "$WORK/windows-nested.zip" omni-dev-0.46.0/LICENSE omni-dev-0.46.0/omni-dev-mcp.exe omni-dev-0.46.0/omni-dev.exe
for order in asc desc; do
  run_step "$WORK/windows-nested.zip" omni-dev-windows.zip "$order"
  expect_installed "zip with a directory, find lists $order" "fake omni-dev.exe"
done

# Two files of that name: `find` prints two lines, and the step must keep one path, not
# hand `mv` both. (Not a layout any release has; it is what makes the first-line cut matter.)
make_zip "$WORK/windows-two.zip" a/omni-dev.exe b/omni-dev.exe omni-dev-mcp.exe
for order in asc desc ""; do
  run_step "$WORK/windows-two.zip" omni-dev-windows.zip "$order"
  expect_installed "zip with two omni-dev.exe, find lists ${order:-as the filesystem does}" "fake omni-dev.exe"
done

# No omni-dev.exe: the step must say so, and must not install what else there is.
make_zip "$WORK/windows-no-binary.zip" LICENSE omni-dev-mcp.exe README.md
for order in asc desc ""; do
  label="zip without omni-dev.exe, find lists ${order:-as the filesystem does}"
  run_step "$WORK/windows-no-binary.zip" omni-dev-windows.zip "$order"
  eq "$label: the step fails" 1 "$STATUS"
  eq "$label: nothing is installed" "" "$(installed_files)"
  has "$label: the error names the archive and the missing file" "$STEP_OUT" \
    "::error::omni-dev-windows.zip has no omni-dev.exe in it"
  has "$label: the error lists what the archive holds" "$STEP_OUT" \
    "It holds: ./LICENSE ./README.md ./omni-dev-mcp.exe"
  eq "$label: the error ends where the list does" "::error::omni-dev-windows.zip has no omni-dev.exe in it, so there is no omni-dev to install. It holds: ./LICENSE ./README.md ./omni-dev-mcp.exe" "$(grep '^::error::' <<<"$STEP_OUT")"
  lacks "$label: it does not claim to have installed" "$STEP_OUT" "Successfully installed"
done

# A name that only starts like the binary's is not it either: omni-dev.exe.sig, omni-dev.bak.
make_zip "$WORK/windows-lookalikes.zip" omni-dev.exe.sig omni-dev.exe.bak omni-dev-mcp.exe
run_step "$WORK/windows-lookalikes.zip" omni-dev-windows.zip asc
eq "zip with look-alikes only: the step fails" 1 "$STATUS"
eq "zip with look-alikes only: nothing is installed" "" "$(installed_files)"

# --- what the step writes ---------------------------------------------------------------

# The cases above prove the rewrite by where the archive went; this proves the other half,
# that the extraction went to the case's directory too, so nothing of a case is left in /tmp.
run_step "$WORK/windows.zip" omni-dev-windows.zip
if [ -d "$CASE/tmp/omni-dev-extract" ]; then ok "the zip is extracted into the case's own directory"; else bad "the zip is extracted into the case's own directory" "no $CASE/tmp/omni-dev-extract"; fi

# Its values arrive in the environment (#39): a script holds no expression. The wiring of
# DOWNLOAD_URL and BINARY_NAME to the platform step's outputs is pinned in
# tests/input-steps.test.sh, which is where every step that reads a value is held to it.
# shellcheck disable=SC2016
eq "script: the step holds no expression" "" "$(grep -n -F '${{' <<<"$DOWNLOAD" || true)"

summary
