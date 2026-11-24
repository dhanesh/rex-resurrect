#!/bin/sh
# Install rex-resurrect.
#   ./install.sh               copy the plugin, hook init.lua, start the saver service
#   ./install.sh --link        symlink instead of copy (for hacking on the plugin)
#   ./install.sh --no-service  don't install the launchd/systemd service
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
MODE=copy SERVICE=yes
for arg in "$@"; do
  case $arg in
    --link) MODE=link ;;
    --no-service) SERVICE=no ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

REX=$(command -v rex || true)
[ -n "$REX" ] || { echo "rex is not on PATH" >&2; exit 1; }
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
REX_DIR=$CONFIG_HOME/rex
INIT=$REX_DIR/init.lua
DEST=$REX_DIR/resurrect
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/rex-resurrect
BEGIN='-- >>> rex-resurrect >>>'
END='-- <<< rex-resurrect <<<'

say() { printf '%s\n' "$*"; }

# 1. Plugin files ------------------------------------------------------------
mkdir -p "$REX_DIR"
if [ -L "$DEST" ] || [ -e "$DEST" ]; then rm -rf "$DEST"; fi
if [ "$MODE" = link ]; then
  ln -s "$SRC/resurrect" "$DEST"
else
  mkdir -p "$DEST"
  cp "$SRC"/resurrect/*.lua "$SRC"/resurrect/*.sh "$DEST"/
fi
chmod +x "$DEST"/*.sh
mkdir -p "$STATE" && chmod 700 "$STATE"
say "✓ plugin $MODE: $DEST"

# 2. init.lua hook (backed up, validated, rolled back on error) --------------
config_ok() { REX_CONFIG="$INIT" "$REX" --autostart=false config check >/dev/null 2>&1; }
if [ -f "$INIT" ] && ! config_ok; then
  say "✗ $INIT already has errors (see: rex config check); fix it first, nothing was changed there" >&2
  exit 1
fi
if ! grep -qF -- "$BEGIN" "$INIT" 2>/dev/null; then
  BACKUP=""
  if [ -f "$INIT" ]; then
    BACKUP="$INIT.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$INIT" "$BACKUP"
  fi
  {
    printf '\n%s\n' "$BEGIN"
    printf '%s\n' '-- Palette actions: Resurrect: Save Now / Restore Saved Sessions / Status.'
    printf '%s\n' '-- pcall: a problem in the plugin can never break the rest of this file.'
    printf '%s\n' 'pcall(function() require("resurrect.actions").setup() end)'
    printf '%s\n' "$END"
  } >>"$INIT"
  if ! config_ok; then
    say "✗ init.lua failed to load after the change; restoring it" >&2
    if [ -n "$BACKUP" ]; then mv "$BACKUP" "$INIT"; else rm -f "$INIT"; fi
    exit 1
  fi
  say "✓ hooked $INIT${BACKUP:+ (backup: $BACKUP)}"
else
  say "✓ $INIT already hooked"
fi
"$REX" --autostart=false config reload >/dev/null 2>&1 && say "✓ Rex reloaded its config" || say "· Rex is not running; config loads when it starts"

# 3. Background saver ------------------------------------------------------------
[ "$SERVICE" = yes ] || { say "· service skipped (--no-service). Run: $DEST/resurrectd.sh"; exit 0; }

case $(uname -s) in
  Darwin)
    LABEL=dev.rex-resurrect
    PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
    mkdir -p "$(dirname "$PLIST")"
    xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>$(xml "$DEST/resurrectd.sh")</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>REX_RESURRECT_REX</key><string>$(xml "$REX")</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>5</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    say "✓ launchd agent $LABEL running (log: $STATE/daemon.log)"
    ;;
  Linux)
    UNIT_DIR=$CONFIG_HOME/systemd/user
    mkdir -p "$UNIT_DIR"
    cat >"$UNIT_DIR/rex-resurrect.service" <<EOF
[Unit]
Description=rex-resurrect: save Rex sessions and offer to restore them

[Service]
Environment="REX_RESURRECT_REX=$REX"
ExecStart=/bin/sh "$DEST/resurrectd.sh"
Restart=always
RestartSec=15
Nice=5
IOSchedulingClass=idle

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now rex-resurrect.service
    say "✓ systemd user service rex-resurrect running (log: $STATE/daemon.log)"
    ;;
  FreeBSD)
    # No per-user service manager: daemon(8) restarts the saver whenever it
    # exits (like launchd KeepAlive), and cron's @reboot starts it at boot.
    PIDF=$STATE/supervisor.pid
    RUN="REX_RESURRECT_REX='$REX' /usr/sbin/daemon -r -R 15 -P '$PIDF' -f /bin/sh '$DEST/resurrectd.sh'"
    # `|| true`: with no crontab yet, grep matches nothing and exits 1, which
    # under set -e would drop the @reboot line below.
    { crontab -l 2>/dev/null | grep -vF -- '# rex-resurrect' || true; printf '@reboot %s # rex-resurrect\n' "$RUN"; } | crontab -
    if [ -f "$PIDF" ]; then kill "$(cat "$PIDF")" 2>/dev/null || true; sleep 1; fi
    sh -c "$RUN"
    say "✓ saver running under daemon(8), started at boot by cron (log: $STATE/daemon.log)"
    ;;
  *)
    say "· no service manager support for $(uname -s); run $DEST/resurrectd.sh yourself"
    ;;
esac
say ""
say "Done. Status: rex do resurrect_status"
