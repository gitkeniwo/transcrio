#!/bin/bash
# Publishes what scripts/release.sh built: the GitHub release (or the rolling `nightly`
# prerelease) and, for a release, the Homebrew tap.
#
#     scripts/publish.sh build/release/1.2.3
#     scripts/publish.sh build/release/nightly
#
# Needs `gh` signed in (GH_TOKEN in CI) with write access to the source repository.
# The tap is pushed with TAP_GITHUB_TOKEN when it is set (CI), otherwise with `gh`.

set -euo pipefail

[ $# -eq 1 ] || { echo "usage: scripts/publish.sh <release output dir>" >&2; exit 64; }
OUT="$(cd "$1" && pwd)"
[ -f "$OUT/release.env" ] || { echo "error: $OUT/release.env missing; run scripts/release.sh first" >&2; exit 1; }
# shellcheck disable=SC1091
source "$OUT/release.env"

REPO="${TRANSCRIO_REPO:-gitkeniwo/transcrio}"
TAP_REPO="${TRANSCRIO_TAP_REPO:-gitkeniwo/homebrew-transcrio}"
ASSETS=("$OUT/$DMG" "$OUT/$WHEEL" "$OUT/SHA256SUMS")

step() { printf '\n==> %s\n' "$*"; }

if [ "$NIGHTLY" = 1 ]; then
  step "Replacing the nightly prerelease with $COMMIT"
  gh release delete nightly --repo "$REPO" --cleanup-tag --yes 2>/dev/null || true
  gh release create nightly "${ASSETS[@]}" --repo "$REPO" --target "$COMMIT" \
    --prerelease --latest=false --title "Transcrio nightly" --notes-file "$OUT/notes.md"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "error: $REPO already has a release $TAG" >&2
  exit 1
fi

step "Creating release $TAG"
gh release create "$TAG" "${ASSETS[@]}" --repo "$REPO" --target "$COMMIT" \
  --title "Transcrio $VERSION" --notes-file "$OUT/notes.md"

step "Updating the tap $TAP_REPO"
TAP_CLONE="$OUT/tap-repo"
rm -rf "$TAP_CLONE"
if [ -n "${TAP_GITHUB_TOKEN:-}" ]; then
  git clone --quiet "https://x-access-token:${TAP_GITHUB_TOKEN}@github.com/$TAP_REPO.git" "$TAP_CLONE"
else
  gh repo clone "$TAP_REPO" "$TAP_CLONE" -- --quiet
fi
cp -R "$OUT/tap/Casks" "$OUT/tap/README.md" "$OUT/tap/transcrio.png" "$TAP_CLONE/"
git -C "$TAP_CLONE" add Casks README.md transcrio.png
if git -C "$TAP_CLONE" diff --cached --quiet; then
  echo "tap already up to date"
else
  git -C "$TAP_CLONE" commit --quiet -m "transcrio $VERSION"
  git -C "$TAP_CLONE" push --quiet
fi

step "Published $TAG: brew install --cask ${TAP_REPO%%/*}/transcrio/transcrio"
