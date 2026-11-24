#!/bin/sh
# Remove rex-resurrect. Saved snapshots are kept unless you pass --purge.
#   ./uninstall.sh [--purge] [--no-service]
# --no-service leaves the background service alone (for an install made with
# ./install.sh --no-service): service names are per account, not per HOME.
set -eu
PURGE=no SERVICE=yes
for arg in "$@"; do
  case $arg in
    --purge) PURGE=yes ;;
    --no-service) SERVICE=no ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
INIT=$CONFIG_HOME/rex/init.lua
DEST=$CONFIG_HOME/rex/resurrect
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/rex-resurrect

case $SERVICE-$(uname -s) in
  yes-Darwin)
    launchctl bootout "gui/$(id -u)/dev.rex-resurrect" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/dev.rex-resurrect.plist" ;;
  yes-Linux)
    systemctl --user disable --now rex-resurrect.service 2>/dev/null || true
    rm -f "$CONFIG_HOME/systemd/user/rex-resurrect.service"
    systemctl --user daemon-reload 2>/dev/null || true ;;
  yes-FreeBSD)
    crontab -l 2>/dev/null | grep -vF -- '# rex-resurrect' | crontab - 2>/dev/null || true
    # Stopping the supervisor also stops the saver it runs.
    [ -f "$STATE/supervisor.pid" ] && kill "$(cat "$STATE/supervisor.pid")" 2>/dev/null || true
    rm -f "$STATE/supervisor.pid" ;;
esac
[ $SERVICE = yes ] && echo "✓ service removed" || echo "· service left alone (--no-service)"

if [ -f "$INIT" ] && grep -qF -- '-- >>> rex-resurrect >>>' "$INIT"; then
  cp "$INIT" "$INIT.bak-$(date +%Y%m%d-%H%M%S)"
  sed -i.tmp '/^-- >>> rex-resurrect >>>$/,/^-- <<< rex-resurrect <<<$/d' "$INIT" && rm -f "$INIT.tmp"
  echo "✓ removed hook from $INIT (backup kept)"
fi
rm -rf "$DEST"
rex --autostart=false config reload >/dev/null 2>&1 || true
echo "✓ plugin files removed"

if [ "$PURGE" = yes ]; then rm -rf "$STATE"; echo "✓ snapshots deleted"
else echo "· snapshots kept in $STATE (use --purge to delete)"; fi
