#!/bin/sh
# Build the release files that get.sh downloads, from a git tag:
#   tools/release.sh v0.1.0             build dist/v0.1.0/{rex-resurrect.tar.gz,SHA256SUMS}
#   tools/release.sh v0.1.0 --publish   also create the GitHub release with them (gh)
# The archive name is fixed so that releases/latest/download/rex-resurrect.tar.gz
# always points at the newest release.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?usage: tools/release.sh TAG [--publish]}
PUBLISH=${2:-}
cd "$ROOT"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "no tag $TAG" >&2; exit 1; }

OUT=$ROOT/dist/$TAG
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rm -rf "$OUT" && mkdir -p "$OUT"
# Only what users need: the plugin and the install scripts (no tests, no tools).
git archive --format=tar --prefix=rex-resurrect/ "$TAG" resurrect bin install.sh uninstall.sh README.md LICENSE CHANGELOG.md | tar -xf - -C "$TMP"
printf '%s\n' "$TAG" >"$TMP/rex-resurrect/VERSION"
# COPYFILE_DISABLE / --no-xattrs: keep macOS metadata out of the archive.
if tar --version 2>/dev/null | grep -q GNU; then
  tar -C "$TMP" --owner=0 --group=0 -czf "$OUT/rex-resurrect.tar.gz" rex-resurrect
else
  COPYFILE_DISABLE=1 tar -C "$TMP" --no-xattrs --uid 0 --gid 0 -czf "$OUT/rex-resurrect.tar.gz" rex-resurrect
fi
(cd "$OUT" && { command -v sha256sum >/dev/null && sha256sum rex-resurrect.tar.gz || shasum -a 256 rex-resurrect.tar.gz; } >SHA256SUMS)
cat "$OUT/SHA256SUMS"
# Homebrew formula for the tap, with this release's version and checksum.
sum=$(cut -d' ' -f1 "$OUT/SHA256SUMS")
sed -e "s/@VERSION@/$TAG/" -e "s/@SHA256@/$sum/" -e '/^# Homebrew formula/,/^# into the tap/d' \
  packaging/homebrew/rex-resurrect.rb >"$OUT/rex-resurrect.rb"
echo "formula: $OUT/rex-resurrect.rb  (copy to dhanesh/homebrew-tap: Formula/rex-resurrect.rb)"

if [ "$PUBLISH" = --publish ]; then
  gh release create "$TAG" "$OUT/rex-resurrect.tar.gz" "$OUT/SHA256SUMS" \
    --title "rex-resurrect $TAG" --notes "Install: curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh | sh"
fi
