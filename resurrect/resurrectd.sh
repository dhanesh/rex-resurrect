#!/bin/sh
# Supervisor entry for launchd/systemd. Waits quietly for a Rex server (never
# starts one), then runs the daemon. When the server stops, the daemon exits
# and the supervisor runs this script again.
DIR=$(cd "$(dirname "$0")" && pwd)
# Find rex: explicit setting, then PATH, then the macOS app's own copy (services
# such as `brew services` don't get the PATH a Rex terminal has).
REX=${REX_RESURRECT_REX:-}
if [ -z "$REX" ]; then
  REX=$(command -v rex 2>/dev/null || true)
  APP="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  [ -z "$REX" ] && [ -x "$APP" ] && REX=$APP
  REX=${REX:-rex}
fi
export REX_RESURRECT_REX="$REX"  # daemon.lua uses it for the restore prompt
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/rex-resurrect
LOG=$STATE/daemon.log
MAX_LOG=524288
# Started from inside a Rex pane, these would make `rex do` target that pane
# (and fail on a server with no sessions). The daemon watches every session.
unset REX_BLOCK REX_SESSION REX_CLIENT

mkdir -p "$STATE" && chmod 700 "$STATE"
# Trim the log before opening it, so it never grows without bound.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt "$MAX_LOG" ]; then
  tail -c $((MAX_LOG / 2)) "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

# Being stopped (launchctl, systemctl, brew services) is a clean exit. `rex do`
# itself exits 130 on SIGTERM, which systemd would record as a failed unit.
trap 'exit 0' TERM INT HUP
until "$REX" --autostart=false server status >/dev/null 2>&1; do
  sleep 10 & wait $!
done
echo "$(date '+%Y-%m-%d %H:%M:%S') rex-resurrect: server is up, starting daemon"
"$REX" --autostart=false do "$DIR/daemon.lua" --all &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT HUP
wait "$child"
rc=$?
# systemd signals the whole group at once, so the daemon can exit from the
# same SIGTERM before the trap above runs: 130/143 mean "interrupted".
case $rc in 130|143) exit 0 ;; esac
# The daemon exited by itself (the server went away): pass its status on, so
# the supervisor runs this script again.
exit $rc
