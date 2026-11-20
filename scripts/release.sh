#!/bin/bash
# Builds a Transcrio release: Transcrio.app in a drag-to-Applications DMG, the
# `transcribe` CLI wheel the app runs (also bundled in the app, which installs it),
# their sha256, the release notes, the rendered Homebrew cask and the tap README.
# Publishing is scripts/publish.sh; the GitHub workflows run both.
#
#     scripts/release.sh 1.2.3       # a release: the version must match pyproject.toml
#     scripts/release.sh --nightly   # a nightly of HEAD, at the pyproject.toml version
#
# The build uses a detached worktree of HEAD, so untracked or uncommitted files never
# end up in it. Bump the version in pyproject.toml and src/transcribe/__init__.py first.
#
# Environment:
#   TRANSCRIO_SIGN_IDENTITY     codesign identity. Default "-" (ad-hoc).
#   TRANSCRIO_CHANGES           a Markdown file whose contents become the "Changes" section
#                               of the release notes.
#   TRANSCRIO_RELEASE_OUT       output directory. Default build/release/<version|nightly>.
#   TRANSCRIO_RELEASE_BASE_URL  download prefix used in the cask. Override it only to test
#                               a local tap (file://...).

set -euo pipefail

REPO="${TRANSCRIO_REPO:-gitkeniwo/transcrio}"
TAP_REPO="${TRANSCRIO_TAP_REPO:-gitkeniwo/homebrew-transcrio}"
BUNDLE_ID="io.github.gitkeniwo.transcribe"

usage() {
  echo "usage: scripts/release.sh <version> | --nightly" >&2
  exit 64
}

[ $# -eq 1 ] || usage
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PY_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml | head -1)"
INIT_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' src/transcribe/__init__.py)"
# `transcribe --version` prints __version__, and the app offers a CLI update when it differs.
if [ "$PY_VERSION" != "$INIT_VERSION" ]; then
  echo "error: pyproject.toml has version '$PY_VERSION' but src/transcribe/__init__.py has '$INIT_VERSION'" >&2
  exit 1
fi

if [ "$1" = "--nightly" ]; then
  NIGHTLY=1
  VERSION="$PY_VERSION"
  TAG="nightly"
  DMG_NAME="Transcrio-nightly.dmg"
else
  NIGHTLY=0
  VERSION="$1"
  TAG="v$VERSION"
  DMG_NAME="Transcrio-$VERSION.dmg"
  if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like 1.2.3, got '$VERSION'" >&2
    exit 64
  fi
  if [ "$PY_VERSION" != "$VERSION" ]; then
    echo "error: pyproject.toml has version '$PY_VERSION', not '$VERSION'; bump it in a commit first" >&2
    exit 1
  fi
fi

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "error: uncommitted changes; the release is built from HEAD, so commit or stash them first:" >&2
  git status --short --untracked-files=no >&2
  exit 1
fi

DEFAULT_BASE_URL="https://github.com/$REPO/releases/download"
SIGN_IDENTITY="${TRANSCRIO_SIGN_IDENTITY:--}"
BASE_URL="${TRANSCRIO_RELEASE_BASE_URL:-$DEFAULT_BASE_URL}"
OUT="${TRANSCRIO_RELEASE_OUT:-$ROOT/build/release/$([ "$NIGHTLY" = 1 ] && echo nightly || echo "$VERSION")}"
COMMIT="$(git rev-parse --short HEAD)"

step() { printf '\n==> %s\n' "$*"; }

SRC="$OUT/src"
if [ -d "$SRC" ]; then git worktree remove --force "$SRC"; fi
rm -rf "$OUT"
mkdir -p "$OUT"
git worktree add --quiet --detach "$SRC" HEAD
trap 'git -C "$ROOT" worktree remove --force "$SRC" 2>/dev/null || true' EXIT

step "Transcrio $VERSION ($TAG, commit $COMMIT), signing identity '$SIGN_IDENTITY'"
echo "output: $OUT"

step "Building the transcribe CLI wheel"
uv build --quiet --wheel --project "$SRC" --out-dir "$OUT"
WHEEL="$OUT/transcribe-$VERSION-py3-none-any.whl"
[ -f "$WHEEL" ] || { echo "error: expected $WHEEL" >&2; ls "$OUT" >&2; exit 1; }

step "Building Transcrio.app"
TRANSCRIBE_APP_VERSION="$VERSION" "$SRC/gui/scripts/bundle.sh" >/dev/null
APP="$OUT/stage/Transcrio.app"
mkdir -p "$OUT/stage"
ditto "$SRC/gui/build/Transcrio.app" "$APP"
# The app installs and updates the CLI from this copy (Install Command-Line Tool), so it
# goes in before signing; the release also hosts it for the manual `uv tool install`.
cp "$WHEEL" "$APP/Contents/Resources/"

step "Signing"
codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
PLIST="$APP/Contents/Info.plist"
echo "CFBundleShortVersionString: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo "architectures:              $(lipo -archs "$APP/Contents/MacOS/Transcrio")"
echo "bundled CLI wheel:          $(cd "$APP/Contents/Resources" && ls transcribe-*.whl)"

step "Making the DMG"
DMG="$OUT/$DMG_NAME"
ln -s /Applications "$OUT/stage/Applications"
VOLNAME="Transcrio $VERSION"
[ "$NIGHTLY" = 1 ] && VOLNAME="Transcrio nightly"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

DMG_SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$WHEEL")" > SHA256SUMS)
cat "$OUT/SHA256SUMS"

step "Rendering the tap"
TAP="$OUT/tap"
mkdir -p "$TAP/Casks"
render() {
  sed -e "s|@VERSION@|$VERSION|g" \
      -e "s|@DMG_SHA256@|$DMG_SHA256|g" \
      -e "s|@BASE_URL@|$BASE_URL|g" \
      -e "s|@REPO@|$REPO|g" \
      -e "s|@TAP_REPO_OWNER@|${TAP_REPO%%/*}|g" \
      -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" "$1" > "$2"
}
render "$SRC/packaging/homebrew-transcrio/Casks/transcrio.rb.in" "$TAP/Casks/transcrio.rb"
render "$SRC/packaging/homebrew-transcrio/README.md" "$TAP/README.md"
# The README's header image: the default icon at 1024 px, with its macOS shadow.
swift "$SRC/gui/scripts/make-icon.swift" "$OUT/iconset" "$SRC/gui/icons/a3b-lcd-clay.svg"
cp "$OUT/iconset/icon_512x512@2x.png" "$TAP/transcrio.png"
if grep -rnI "@[A-Z_0-9]*@" "$TAP"; then
  echo "error: unrendered placeholders above" >&2
  exit 1
fi

NOTES="$OUT/notes.md"
{
  if [ "$NIGHTLY" = 1 ]; then
    cat <<EOF
Automated build of \`main\` at $COMMIT ($(date -u '+%Y-%m-%d %H:%M UTC')). Untested; for a stable
version use the [latest release](https://github.com/$REPO/releases/latest).

Download **$DMG_NAME**, open it and drag Transcrio into Applications. Transcrio installs the
bundled \`transcribe\` tool when you click **Install Command-Line Tool**. It isn't notarized: the
first time you open it, go to **System Settings › Privacy & Security** and click **Open Anyway**.
EOF
  else
    cat <<EOF
## Install

\`\`\`sh
brew install --cask ${TAP_REPO%%/*}/transcrio/transcrio
\`\`\`

Or download **$DMG_NAME** below, open it and drag Transcrio into Applications.

Transcrio runs the \`transcribe\` command-line tool, which it installs itself: open Transcrio and click
**Install Command-Line Tool** (and **Update Command-Line Tool** after an upgrade). It needs
[uv](https://docs.astral.sh/uv/) and \`ffmpeg\`; the cask installs both, otherwise:

\`\`\`sh
brew install uv ffmpeg
\`\`\`

To install the tool by hand instead (it also ships below as a wheel):

\`\`\`sh
uv tool install --force --python 3.12 $BASE_URL/$TAG/transcribe-$VERSION-py3-none-any.whl
\`\`\`

Transcrio isn't notarized. The first time you open it, macOS blocks it: go to
**System Settings › Privacy & Security**, find *"Transcrio" was blocked…* and click **Open Anyway**.

Requires macOS 14 (Sonoma) or later on Apple silicon.
EOF
  fi
  if [ -n "${TRANSCRIO_CHANGES:-}" ]; then
    printf '\n## Changes\n\n'
    cat "$TRANSCRIO_CHANGES"
  fi
  printf '\n<sub>Source commit %s.</sub>\n' "$COMMIT"
} > "$NOTES"

# For scripts/publish.sh.
cat > "$OUT/release.env" <<EOF
TAG=$TAG
VERSION=$VERSION
NIGHTLY=$NIGHTLY
COMMIT=$(git rev-parse HEAD)
DMG=$(basename "$DMG")
WHEEL=$(basename "$WHEEL")
EOF

step "Built $TAG in $OUT"
ls -1 "$OUT"
echo "To publish: scripts/publish.sh $OUT"
