#!/bin/bash
# The shell hook (resurrect/shell/) against a throwaway Rex server: per-block
# history and output survive a restart, both when Rex keeps the blocks and
# when the plugin rebuilds them. Never touches your own server, shell config
# or history: the server, its shell's config and history, and all state are
# under a temp dir.
#   tests/shell-e2e.sh [zsh|bash]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH=${1:-zsh}
command -v "$SH" >/dev/null || { echo "$SH not installed; skipping"; exit 0; }
if [ "$SH" = bash ] && [ "$(uname -s)" = Darwin ]; then
  # Rex starts macOS shells through login(1), which resets HOME, so a bash
  # test would read your real ~/.bash_profile. Run it on Linux (tests/linux.sh).
  echo "bash variant runs on Linux only; skipping"; exit 0
fi
T=$(mktemp -d /tmp/rrs.XXXXXX) || exit 1  # short: unix socket paths are limited to ~104 bytes
export REX_SERVER="unix://$T/s.sock"
export XDG_STATE_HOME=$T/state XDG_CONFIG_HOME=$T/config ZDOTDIR=$T/zdot
export REX_RESURRECT_REX=$(command -v rex)
unset REX_BLOCK REX_SESSION REX_CLIENT
STATE=$XDG_STATE_HOME/rex-resurrect

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ✓ $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ✗ $*"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
X() { rex --autostart=false "$@"; }
jq_() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
wait_for() { local n=$(( $1 * 4 )); shift; for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
screen() { X capture -s "$1" -b "$2" --trim 2>/dev/null; }
shows() { screen "$1" "$2" | grep -q -- "$3"; }

server_pid="" daemon_pid=""
start_server() {
  SHELL=$(command -v "$SH") rex server run --listen "$REX_SERVER" --state-dir "$T/server-state" --config "$T/init.lua" "$@" >>"$T/server.log" 2>&1 &
  server_pid=$!
  wait_for 10 X server status || { echo "server did not start"; exit 1; }
  X server status | grep -qF "$T/s.sock" || { echo "not the test server"; exit 1; }
}
stop_server() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=""; }
start_daemon() { rex --autostart=false do "$ROOT/resurrect/daemon.lua" --all >>"$T/daemon.log" 2>&1 & daemon_pid=$!; }
restart() { sleep 2.5; stop_server; wait_for 5 bash -c "! kill -0 $daemon_pid"; start_server "$@"; start_daemon; }
crash() { # like a power cut: the server gets no chance to shut down cleanly
  sleep 2.5; kill -9 "$server_pid"; wait "$server_pid" 2>/dev/null; server_pid=""
  wait_for 5 bash -c "! kill -0 $daemon_pid"; start_server; start_daemon
}
cleanup() {
  [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null; stop_server
  if [ "$FAIL" -eq 0 ]; then rm -rf "$T"; else echo "kept for inspection: $T"; fi
}
trap cleanup EXIT

mkdir -p "$ZDOTDIR" "$XDG_CONFIG_HOME/rex"
cat >"$T/init.lua" <<EOF
package.path = "$ROOT/?.lua;" .. package.path
pcall(function() require("resurrect.actions").setup() end)
EOF
cat >"$XDG_CONFIG_HOME/rex/resurrect-config.lua" <<'EOF'
return { min_save_interval = 1, save_debounce = 0.5, settle_delay = 1, confirm_interval = 1, scrollback_poll = 1 }
EOF
if [ "$SH" = zsh ]; then
  cat >"$ZDOTDIR/.zshrc" <<EOF
HISTFILE=$T/zhist SAVEHIST=1000 HISTSIZE=1000
setopt sharehistory histignorespace
PS1='P%# '
source "$ROOT/resurrect/shell/rex-resurrect.zsh"
EOF
else
  export HOME=$T/home
  mkdir -p "$HOME"
  echo '. ~/.bashrc' >"$HOME/.bash_profile"
  cat >"$HOME/.bashrc" <<EOF
HISTFILE=$T/bhist HISTCONTROL=ignorespace PS1='P% '
shopt -s histappend; PROMPT_COMMAND='history -a'
. "$ROOT/resurrect/shell/rex-resurrect.bash"
EOF
fi
bdir() { echo "$STATE/blocks/${1#block:}"; }
run() { X send -s "$1" -b "$2" "$3" && X send-key -s "$1" -b "$2" enter; sleep 0.4; }

echo "1. Hooked shell, saved output"
start_server
start_daemon
SID=$(X new shellt -c /tmp --json | jq_ 'd["session_id"]')
B=$(X block ls -s "$SID" --json | jq_ 'd["blocks"][0]["block_id"]')
check "$SH with the hook starts" wait_for 10 shows "$SID" "$B" 'P%'
run "$SID" "$B" 'echo marker-$((6*7))'
run "$SID" "$B" ' echo secret-$((1+1))'
run "$SID" "$B" 'echo second-cmd'
check "block history records commands" wait_for 5 grep -qx 'echo second-cmd' "$(bdir "$B")/history"
check "  but not ones starting with a space" sh -c "! grep -q secret '$(bdir "$B")/history'"
check "output saved" wait_for 10 grep -q 'marker-42' "$(bdir "$B")/scrollback"
check "  as plain text" sh -c "! grep -q \$(printf '\\033') '$(bdir "$B")/scrollback'"
sleep 1.5; run "$SID" "$B" 'ls >/dev/null'   # a command, but no layout change
check "snapshot confirmed current (checked.json)" wait_for 10 test -s "$STATE/checked.json"
# A second block runs the newest command, so up-arrow in the first block
# only shows its own last command if the hook works.
B2=$(X split -s "$SID" -b "$B" --split=right -c /tmp --json | jq_ 'd.get("block_id") or ""')
[ -n "$B2" ] || B2=$(X block ls -s "$SID" --json | jq_ '[b["block_id"] for b in d["blocks"]][-1]')
check "second block starts" wait_for 10 shows "$SID" "$B2" 'P%'
run "$SID" "$B2" 'echo other-block-cmd'
check "  its command is recorded in its own file" wait_for 5 grep -qx 'echo other-block-cmd' "$(bdir "$B2")/history"

echo "2. Power-cut restart; Rex restores the blocks itself"
crash
check "block keeps its id" wait_for 10 shows "$SID" "$B" 'P%'
check "old output printed once, dimmed" wait_for 5 shows "$SID" "$B" 'output from before Rex restarted'
check "  with its content" shows "$SID" "$B" 'marker-42'
check "  and deleted once printed" test ! -e "$(bdir "$B")/scrollback.shown"
X send-key -s "$SID" -b "$B" up; sleep 0.5
check "up-arrow shows this block's last command, not the other block's newer one" bash -c "rex --autostart=false capture -s '$SID' -b '$B' --trim | tail -1 | grep -q 'ls >/dev/null'"
X send-key -s "$SID" -b "$B" ctrl+u
run "$SID" "$B" "$SH -i"
run "$SID" "$B" 'echo nested-done'
check "a nested shell doesn't print it again" bash -c "[ \$(rex --autostart=false capture -s '$SID' -b '$B' --trim | grep -c 'output from before') = 1 ]"
run "$SID" "$B" 'exit'
check "pending snapshot kept when it was last confirmed" bash -c "ls '$STATE/history' | grep -q pre-restart && grep -q checked_at '$STATE/history/'*pre-restart*"

echo "3. The plugin rebuilds the block (Rex skipped it)"
run "$SID" "$B" 'echo rebuilt-marker'
check "new output saved" wait_for 10 grep -q 'rebuilt-marker' "$(bdir "$B")/scrollback"
restart --restore=false
PSID=$(X session ls --json | jq_ '[s["session_id"] for s in d["sessions"]][0]')
PB=$(X block ls -s "$PSID" --json | jq_ '([b["block_id"] for b in d["blocks"] if b.get("label")=="rex-resurrect"] or [""])[0]')
check "prompt offered" wait_for 10 shows "$PSID" "$PB" 'Restore now'
X send -s "$PSID" -b "$PB" 'y' && X send-key -s "$PSID" -b "$PB" enter
check "session rebuilt" wait_for 10 bash -c "rex --autostart=false session ls --json | grep -q shellt"
NSID=$(X session ls --json | jq_ '[s["session_id"] for s in d["sessions"] if s.get("label")=="shellt"][0]')
NB=$(X block ls -s "$NSID" --json | jq_ 'd["blocks"][0]["block_id"]')  # the left pane, B's
check "new block id" test "$NB" != "$B"
check "rebuilt block prints the old output" wait_for 10 shows "$NSID" "$NB" 'rebuilt-marker'
check "files moved to the new block" test -d "$(bdir "$NB")" -a ! -e "$(bdir "$B")"
check "  history merged into the new block's file" grep -qx 'echo rebuilt-marker' "$(bdir "$NB")/history"
check "  nothing left to pick up" bash -c "! ls '$(bdir "$NB")' | grep -q restore"
X send-key -s "$NSID" -b "$NB" up; sleep 0.5
check "up-arrow brings back the old block's command" bash -c "rex --autostart=false capture -s '$NSID' -b '$NB' --trim | tail -1 | grep -q 'echo rebuilt-marker'"

echo "4. Saver log"
check "no errors or warnings from the plugin" sh -c "! grep -E '^(error|warn): \\[resurrect\\]' '$T/daemon.log'"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { echo "--- daemon log"; tail -20 "$T/daemon.log"; }
[ "$FAIL" -eq 0 ]
