#!/bin/bash
# End-to-end test against a throwaway Rex server. Never touches the user's
# own server, config or state: everything lives under .t/e2e.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$ROOT/.t/e2e
SOCK=$T/s.sock
export REX_SERVER="unix://$SOCK"
export XDG_STATE_HOME=$T/xdg-state
export XDG_CONFIG_HOME=$T/xdg-config
export REX_RESURRECT_REX=$(command -v rex)
# This test may itself run inside a Rex pane; don't let that pane be the target.
unset REX_BLOCK REX_SESSION REX_CLIENT
STATE=$XDG_STATE_HOME/rex-resurrect

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ✓ $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ✗ $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
X() { rex --autostart=false "$@"; }
jq_() { python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# Portable stat: BSD/macOS and GNU/Linux spell these differently.
if [ "$(uname -s)" = Linux ]; then
  perm()  { stat -c %a "$1"; }
  mtime() { stat -c %Y "$1"; }
else
  perm()  { stat -f %Lp "$1"; }
  mtime() { stat -f %m "$1"; }
fi
real() { (cd "$1" && pwd -P); }  # macOS reports /etc as /private/etc
wait_for() { # wait_for SECONDS cmd...
  local n=$(( $1 * 4 )); shift
  for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1
}

server_pid=""
start_server() {
  rex server run --listen "$REX_SERVER" --state-dir "$T/server-state" --config "$T/cfg/init.lua" "$@" >>"$T/server.log" 2>&1 &
  server_pid=$!
  wait_for 10 X server status || { echo "server did not start"; exit 1; }
}
stop_server() { [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=""; }

daemon_pid=""
start_daemon() {
  rex --autostart=false do "$ROOT/resurrect/daemon.lua" --all >>"$T/daemon.log" 2>&1 &
  daemon_pid=$!
}
cleanup() { [ -n "$daemon_pid" ] && kill "$daemon_pid" 2>/dev/null; stop_server; }
trap cleanup EXIT

rm -rf "$T" && mkdir -p "$T/cfg" "$XDG_CONFIG_HOME/rex"
cat >"$T/cfg/init.lua" <<EOF
package.path = "$ROOT/?.lua;" .. package.path
pcall(function() require("resurrect.actions").setup() end)
EOF
cat >"$XDG_CONFIG_HOME/rex/resurrect-config.lua" <<'EOF'
return { min_save_interval = 1, save_debounce = 0.5, settle_delay = 1 }
EOF

session_json() { X session inspect "$1" --json 2>/dev/null; }
pane_cwds() { # sorted cwd of every pane in session $1
  local sid=$1
  X block ls -s "$sid" --json | jq_ '"\n".join(b["block_id"] for b in d["blocks"])' | while read -r b; do
    [ -n "$b" ] && X block call -s "$sid" -b "$b" process | jq_ '(d.get("foreground") or {}).get("cwd") or d["ancestors"][0].get("cwd")'
  done | sort | tr '\n' ' '
}
fg_names() {
  local sid=$1
  X block ls -s "$sid" --json | jq_ '"\n".join(b["block_id"] for b in d["blocks"])' | while read -r b; do
    [ -n "$b" ] && X block call -s "$sid" -b "$b" process | jq_ '(d.get("foreground") or {}).get("argv0") or "-"'
  done | sort | tr '\n' ' '
}

echo "1. Saving"
start_server
SID=$(X new alpha -c /usr --json | jq_ 'd["session_id"]')
B1=$(X block ls -s "$SID" --json | jq_ 'd["blocks"][0]["block_id"]')
X split -s "$SID" -b "$B1" --split=right -c /etc --json >/dev/null
X window new -s "$SID" editor -c /var --json >/dev/null
B3=$(X block ls -s "$SID" --json | jq_ '[b for b in d["blocks"]][-1]["block_id"]')
sleep 1
X send -s "$SID" -b "$B3" 'less /etc/hosts' && X send-key -s "$SID" -b "$B3" enter
sleep 1
start_daemon
check "daemon writes last.json" wait_for 10 test -s "$STATE/last.json"
sleep 2
count=$(X do "$ROOT/resurrect/ctl.lua" cmd=status --json | jq_ '"%s/%s/%s" % (d.get("sessions"), d.get("windows"), d.get("panes"))')
check "snapshot has 1 session, 2 windows, 3 panes (got $count)" test "$count" = "1/2/3"
check "less is recorded with its argv" grep -q '"argv":\["less","/etc/hosts"\]' "$STATE/last.json"
check "state dir is private (0700)" test "$(perm "$STATE")" = 700

echo "2. Saves on triggers, and only on change"
before=$(mtime "$STATE/last.json")
X window new -s "$SID" extra -c /tmp --json >/dev/null
check "new window saved within 6s" wait_for 6 grep -q '"label":"extra"' "$STATE/last.json"
X window close -s "$SID" extra >/dev/null 2>&1
check "closed window removed within 6s" wait_for 6 bash -c "! grep -q '\"label\":\"extra\"' '$STATE/last.json'"
check "closing archives the previous snapshot? (window close is not a session loss: none)" bash -c "! ls '$STATE/history' | grep -q before-close"
m1=$(mtime "$STATE/last.json"); sleep 4; m2=$(mtime "$STATE/last.json")
check "idle server causes no writes" test "$m1" = "$m2"

echo "3. Server restart where Rex does NOT restore (simulated with --restore=false)"
stop_server
check "daemon exits when server goes away" wait_for 5 bash -c "! kill -0 $daemon_pid"
start_server --restore=false
start_daemon
check "pending.json frozen before any new save" wait_for 8 test -s "$STATE/pending.json"
check "prompt session created" wait_for 8 bash -c "rex --autostart=false ls --json | grep -q '\"resurrect\"'"
PSID=$(X ls --json | jq_ '[s for s in d["sessions"] if s["label"]=="resurrect"][0]["session_id"]')
PB=$(X block ls -s "$PSID" --json | jq_ 'd["blocks"][0]["block_id"]')
check "prompt lists the missing session" wait_for 5 bash -c "rex --autostart=false capture -s '$PSID' -b '$PB' --trim | grep -q alpha"
X capture -s "$PSID" -b "$PB" --trim | sed 's/^/      | /'
X send -s "$PSID" -b "$PB" 'y' && X send-key -s "$PSID" -b "$PB" enter
check "alpha restored" wait_for 15 bash -c "rex --autostart=false ls --json | grep -q '\"alpha\"'"
NSID=$(X ls --json | jq_ '[s for s in d["sessions"] if s["label"]=="alpha"][0]["session_id"]')
sleep 3
windows=$(session_json "$NSID" | jq_ 'len(d["windows"])')
check "restored 2 windows (got $windows)" test "$windows" = 2
labels=$(session_json "$NSID" | jq_ '",".join(w.get("label","") for w in d["windows"])')
check "window label 'editor' kept (got $labels)" bash -c "echo '$labels' | grep -q editor"
cwds=$(pane_cwds "$NSID")
want="$(printf '%s\n' "$(real /etc)" "$(real /var)" "$(real /usr)" | sort | tr '\n' ' ')"
check "pane folders restored (got: $cwds)" test "$cwds" = "$want"
names=$(fg_names "$NSID")
check "less relaunched (foregrounds: $names)" bash -c "echo '$names' | grep -q less"
check "pending cleared after restore" wait_for 5 bash -c "! test -e '$STATE/pending.json'"
check "pre-restart snapshot archived" bash -c "ls '$STATE/history' | grep -q pre-restart"

prompt_block() { # block id of the floating prompt in session $1, if any
  X block ls -s "$1" --json 2>/dev/null | jq_ '([b["block_id"] for b in d["blocks"] if b.get("label")=="rex-resurrect"] or [""])[0]'
}
restart_native() {
  sleep 2.5 # let the daemon save the latest state
  stop_server
  wait_for 5 bash -c "! kill -0 $daemon_pid"
  start_server
  start_daemon
}

sid_of() { X ls --json | jq_ "([s['session_id'] for s in d['sessions'] if s['label']=='$1'] or [''])[0]"; }

echo "4. Server restart where Rex restores natively, with a program to reopen"
# Note: step 3's server ran with --restore=false, which also saves nothing, so
# Rex now brings back its step-1 copy of alpha with different block IDs. This
# exercises the positional pane matching.
check "less was recorded for the restored session" wait_for 6 grep -q '"argv":\["less","/etc/hosts"\]' "$STATE/last.json"
restart_native
check "Rex restored alpha itself" wait_for 5 bash -c "rex --autostart=false ls --json | grep -q '\"alpha\"'"
NSID=$(sid_of alpha)
check "floating prompt offered in alpha" wait_for 10 bash -c "[ -n \"\$(rex --autostart=false block ls -s '$NSID' --json | grep rex-resurrect)\" ]"
PB=$(prompt_block "$NSID")
check "prompt offers to reopen less" wait_for 5 bash -c "rex --autostart=false capture -s '$NSID' -b '$PB' --trim | grep -q 'less /etc/hosts'"
X capture -s "$NSID" -b "$PB" --trim | sed -n '/rex-resurrect/,$p' | sed 's/^/      | /'
X send-key -s "$NSID" -b "$PB" enter   # plain Enter = the default, Yes
for _ in $(seq 1 40); do fg_names "$NSID" 2>/dev/null | grep -q less && break; sleep 0.25; done
names=$(fg_names "$NSID" 2>/dev/null)
check "less running again in the restored pane (foregrounds: $names)" bash -c "echo '$names' | grep -q less"
n=$(X ls --json | jq_ 'len(d["sessions"])')
check "no duplicate sessions (sessions: $n)" test "$n" = 1
check "pending resolved" wait_for 5 bash -c "! test -e '$STATE/pending.json'"

echo "5. Declining"
OLD_SID=$NSID
restart_native
NSID=$(sid_of alpha)
check "Rex keeps session IDs across its own restore" test "$NSID" = "$OLD_SID"
check "prompt offered again" wait_for 10 bash -c "[ -n \"\$(rex --autostart=false block ls -s '$NSID' --json | grep rex-resurrect)\" ]"
PB=$(prompt_block "$NSID")
wait_for 5 bash -c "rex --autostart=false capture -s '$NSID' -b '$PB' --trim | grep -q 'Restore now'"
X send -s "$NSID" -b "$PB" 'n' && X send-key -s "$NSID" -b "$PB" enter
check "declined snapshot archived" wait_for 6 bash -c "ls '$STATE/history' | grep -q declined"
check "pending cleared" bash -c "! test -e '$STATE/pending.json'"
check "prompt closes itself" wait_for 6 bash -c "[ -z \"\$(rex --autostart=false block ls -s '$NSID' --json | grep rex-resurrect)\" ]"
restart_native
sleep 4
check "no prompt after a decline when nothing new is missing" bash -c "[ -z \"\$(rex --autostart=false block ls -s '$NSID' --json | grep rex-resurrect)\" ]"
check "restore from history is available" bash -c "rex --autostart=false do '$ROOT/resurrect/ctl.lua' cmd=status --json | grep -q '\"history\"'"

echo "6. Palette actions"
out=$(X do resurrect_status --json 2>&1)
check "resurrect_status action works" bash -c "echo '$out' | grep -q '\"sessions\"'"
out=$(X do resurrect_save --json 2>&1)
check "resurrect_save action works" bash -c "echo '$out' | grep -q '\"ok\": true'"

echo "7. Daemon log has no errors"
# "server went away" is rex itself reporting the (intentional) server stops.
check "no error lines" bash -c "! grep -iE 'error|failed|warn' '$T/daemon.log' | grep -v 'server went away'"
[ "$FAIL" -gt 0 ] && { echo "--- daemon.log"; tail -30 "$T/daemon.log"; }

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
