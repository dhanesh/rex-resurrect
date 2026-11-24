#!/bin/sh
# Tests get.sh against a local, file:// copy of a GitHub release layout, in a
# sandboxed HOME. Never touches your real config, saver or Rex server:
#   tests/get-test.sh             --no-service (safe on a machine you use)
#   tests/get-test.sh --service   also installs the saver service (throwaway machines only)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SERVICE=no; [ "${1:-}" = --service ] && SERVICE=yes
if [ $SERVICE = yes ] && [ "$(uname -s)" = Darwin ]; then
  # launchd agents are per account, and --service uses the real home: on a Mac
  # this would replace, then remove, the live install.
  echo "--service is for throwaway Linux/FreeBSD machines, not macOS" >&2; exit 2
fi
REAL_REX=$(command -v rex) || { echo "rex not on PATH"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/rr-get.XXXXXX")
trap 'rm -rf "$T"' EXIT
unset REX_BLOCK REX_SESSION REX_CLIENT

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✓ $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  ✗ $*"; }
check() { d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has() { printf '%s\n' "$1" | grep -q -- "$2"; }  # has TEXT PATTERN, safe with any quotes
sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
        elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1
        else sha256 -q "$1"; fi; }

# A `rex` that passes everything through except `config reload`, so installing
# into the sandbox can't make a real server reload its config.
mkdir -p "$T/bin"
cat >"$T/bin/rex" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = reload ] && exit 1; done
exec "$REAL_REX" "\$@"
EOF
chmod +x "$T/bin/rex"

# Release layout: BASE/download/TAG/{rex-resurrect.tar.gz,SHA256SUMS} and BASE/latest/download/...
mkrelease() { # tag [corrupt]
  d=$T/rel/download/$1; mkdir -p "$d" "$T/stage/$1/rex-resurrect"
  (cd "$ROOT" && cp -R resurrect bin install.sh uninstall.sh README.md "$T/stage/$1/rex-resurrect/")
  echo "$1" >"$T/stage/$1/rex-resurrect/VERSION"
  COPYFILE_DISABLE=1 tar -C "$T/stage/$1" -czf "$d/rex-resurrect.tar.gz" rex-resurrect 2>/dev/null
  echo "$(sha "$d/rex-resurrect.tar.gz")  rex-resurrect.tar.gz" >"$d/SHA256SUMS"
  [ "${2:-}" = corrupt ] && printf 'x' >>"$d/rex-resurrect.tar.gz"
  return 0
}
mkrelease v9.9.8 corrupt
mkrelease v9.9.9
mkdir -p "$T/rel/latest" && cp -R "$T/rel/download/v9.9.9" "$T/rel/latest/download"

if [ $SERVICE = yes ]; then
  # Service managers only look in the real home (e.g. ~/.config/systemd/user),
  # so --service installs for real: throwaway machines only.
  H=$HOME; unset XDG_CONFIG_HOME XDG_STATE_HOME
else
  H=$T/home
  export HOME=$H XDG_CONFIG_HOME=$H/.config XDG_STATE_HOME=$H/.local/state
fi
export TMPDIR=$T/tmp REX_RESURRECT_BASE_URL="file://$T/rel"
mkdir -p "$H" "$TMPDIR"
OPT=""; [ $SERVICE = no ] && OPT=--no-service
PLUGIN=$H/.config/rex/resurrect INIT=$H/.config/rex/init.lua
get() { PATH="$T/bin:$PATH" sh -s -- "$@" <"$ROOT/get.sh"; }  # stdin, like curl | sh
# Everything an install touches: rex config, saved state, user services, crontab.
snapshot() {
  for d in "$H/.config/rex" "$H/.local/state/rex-resurrect" "$H/.config/systemd/user" "$H/Library/LaunchAgents"; do
    [ -e "$d" ] && find "$d" | LC_ALL=C sort
  done
  crontab -l 2>/dev/null || true
}

echo "1. Failures change nothing"
before=$(snapshot)
out=$(get --version v9.9.8 $OPT 2>&1); rc=$?
check "bad checksum fails" test $rc -ne 0
check "  and says so" has "$out" 'checksum mismatch'
out=$(get --version v1.2.3 $OPT 2>&1); rc=$?
check "unknown version fails" test $rc -ne 0
check "  with a clear message" has "$out" 'does that release exist'
out=$(PATH=/usr/bin:/bin sh -s -- $OPT <"$ROOT/get.sh" 2>&1); rc=$?
check "missing rex fails" test $rc -ne 0
check "  with a clear message" has "$out" 'rex is not on PATH'
check "--link is refused" sh -c "! PATH='$T/bin:$PATH' sh -s -- --link <'$ROOT/get.sh' 2>/dev/null"
check "--purge without --uninstall is refused" sh -c "! PATH='$T/bin:$PATH' sh -s -- --purge <'$ROOT/get.sh' 2>/dev/null"
check "bad --version value is refused" sh -c "! PATH='$T/bin:$PATH' sh -s -- --version latest <'$ROOT/get.sh' 2>/dev/null"
size=$(wc -c <"$ROOT/get.sh")
for cut in 200 $((size / 2)) $((size - 30)) $((size - 2)); do
  head -c $cut "$ROOT/get.sh" | PATH="$T/bin:$PATH" sh >/dev/null 2>&1
done
check "truncated downloads (4 cut points) run nothing" test "$(snapshot)" = "$before"
check "no temp folders left behind" test -z "$(ls "$TMPDIR")"

echo "2. Install"
out=$(get --version v9.9.9 $OPT 2>&1); rc=$?
echo "$out" | sed 's/^/      | /'
check "pinned install succeeds" test $rc -eq 0
check "prints the version" has "$out" 'rex-resurrect v9.9.9'
check "plugin installed" test -f "$PLUGIN/daemon.lua"
check "shell hooks installed" test -f "$PLUGIN/shell/rex-resurrect.zsh" -a -f "$PLUGIN/shell/rex-resurrect.bash"
check "init.lua hooked" grep -qF -- '-- >>> rex-resurrect >>>' "$INIT"
check "config valid" env REX_CONFIG="$INIT" "$REAL_REX" --autostart=false config check
check "temp folder removed" test -z "$(ls "$TMPDIR")"
if [ $SERVICE = yes ]; then
  case $(uname -s) in
    Linux)   check "systemd service active" systemctl --user is-active rex-resurrect.service ;;
    FreeBSD) check "supervisor running" sh -c "kill -0 \$(cat '$H/.local/state/rex-resurrect/supervisor.pid')" ;;
  esac
fi

echo "3. Latest, re-run"
check "latest (no --version) installs" get $OPT
check "re-run keeps a single hook" test "$(grep -cF -- '-- >>> rex-resurrect >>>' "$INIT")" = 1

echo "4. Uninstall"
check "--uninstall succeeds" get --uninstall $OPT
check "plugin removed" test ! -e "$PLUGIN"
check "hook removed" sh -c "! grep -qF rex-resurrect '$INIT'"
if [ $SERVICE = yes ]; then
  case $(uname -s) in
    Linux)   check "systemd service removed" sh -c "! systemctl --user cat rex-resurrect.service" ;;
    FreeBSD) check "cron entry and supervisor removed" sh -c "! crontab -l 2>/dev/null | grep -q rex-resurrect && ! pgrep -f '^daemon: .*sh\['" ;;
  esac
fi
check "temp folder removed" test -z "$(ls "$TMPDIR")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
