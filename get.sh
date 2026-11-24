#!/bin/sh
# Install rex-resurrect from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh | sh -s -- --version v0.1.1
#   curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh | sh -s -- --uninstall
#   (FreeBSD: fetch -o - <same URL> | sh)
#
# Options:
#   --version TAG   install that release (default: the latest)
#   --no-service    don't install the background saver service
#   --uninstall     remove rex-resurrect (add --purge to delete saved snapshots)
#
# It downloads the release archive, checks it against the release's SHA256SUMS,
# runs the archive's install.sh (or uninstall.sh) and deletes the download.
# It never needs root. Environment, for mirrors and testing:
#   REX_RESURRECT_REPO      owner/name on GitHub (default dhanesh/rex-resurrect)
#   REX_RESURRECT_BASE_URL  where releases live; files are fetched from
#                           BASE/latest/download/NAME or BASE/download/TAG/NAME

# Everything is in a function that runs on the last line, so a download cut off
# partway through runs nothing.
rex_resurrect_get() {
  set -eu
  REPO=${REX_RESURRECT_REPO:-dhanesh/rex-resurrect}
  BASE=${REX_RESURRECT_BASE_URL:-https://github.com/$REPO/releases}
  VERSION="" ACTION=install PASS=""

  die() { printf 'rex-resurrect: %s\n' "$*" >&2; exit 1; }
  while [ $# -gt 0 ]; do
    case $1 in
      --version) [ $# -ge 2 ] || die "--version needs a tag, such as v0.1.1"; VERSION=$2; shift ;;
      --version=*) VERSION=${1#--version=} ;;
      --no-service) PASS="$PASS --no-service" ;;
      --purge) PASS="$PASS --purge" ;;
      --uninstall) ACTION=uninstall ;;
      --link) die "--link needs a checkout to point at; clone the repo and run ./install.sh --link" ;;
      -h|--help) sed -n '2,19p' "$0" 2>/dev/null || echo "see https://github.com/$REPO"; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  case $VERSION in ""|v[0-9]*) ;; *) die "--version takes a tag such as v0.1.1, not '$VERSION'" ;; esac
  case "$ACTION$PASS" in
    install*--purge*) die "--purge goes with --uninstall" ;;
  esac

  if [ "$ACTION" = install ]; then
    command -v rex >/dev/null 2>&1 || die "rex is not on PATH; install Rex first: https://www.superlogical.com/rex"
  fi
  command -v tar >/dev/null 2>&1 || die "tar is needed"

  if command -v curl >/dev/null 2>&1; then
    download() { curl -fsSL --retry 2 -o "$2" "$1"; }
  elif command -v fetch >/dev/null 2>&1; then
    download() { fetch -q -o "$2" "$1"; }
  elif command -v wget >/dev/null 2>&1; then
    download() { wget -q -O "$2" "$1"; }
  else
    die "curl, fetch or wget is needed"
  fi
  if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$1" | cut -d' ' -f1; }
  elif command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
  elif command -v sha256 >/dev/null 2>&1; then sha() { sha256 -q "$1"; }
  else die "sha256sum, shasum or sha256 is needed to check the download"
  fi

  if [ -n "$VERSION" ]; then url="$BASE/download/$VERSION"; else url="$BASE/latest/download"; fi
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/rex-resurrect.XXXXXX")
  trap 'rm -rf "$TMP"' EXIT
  trap 'exit 1' HUP INT TERM

  NAME=rex-resurrect.tar.gz
  download "$url/SHA256SUMS" "$TMP/SHA256SUMS" ||
    die "could not download ${VERSION:-the latest} release from $url (does that release exist?)"
  download "$url/$NAME" "$TMP/$NAME" || die "could not download $url/$NAME"
  want=$(awk -v n="$NAME" '$2 == n || $2 == "*" n { print $1 }' "$TMP/SHA256SUMS")
  [ -n "$want" ] || die "SHA256SUMS has no entry for $NAME"
  got=$(sha "$TMP/$NAME")
  [ "$got" = "$want" ] || die "checksum mismatch for $NAME (expected $want, got $got); nothing was installed"

  mkdir "$TMP/src"
  tar -xzf "$TMP/$NAME" -C "$TMP/src"
  SRC=$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [ -n "$SRC" ] && [ -f "$SRC/install.sh" ] || die "the archive doesn't look like rex-resurrect"
  [ -f "$SRC/VERSION" ] && printf 'rex-resurrect %s\n' "$(cat "$SRC/VERSION")"

  # Run from the unpacked copy; install.sh copies files into ~/.config/rex, so
  # deleting the download afterwards is safe. </dev/null: stdin is this script.
  # shellcheck disable=SC2086
  sh "$SRC/$ACTION.sh" $PASS </dev/null
}

rex_resurrect_get "$@"
