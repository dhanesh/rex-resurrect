#!/usr/local/bin/bash
# FreeBSD test on a throwaway VM (e.g. `limactl start template://freebsd`):
# unit + e2e suites, then a real install (daemon(8) + cron @reboot), a Rex
# restart, re-attach and uninstall. Expects the repo in ~/rr. Never run it on
# a machine you use: it stops and starts that machine's Rex server.
set -u
# The checkout this script is in; piped in over stdin (bash -s), the copy at ~/rr.
ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -f "$ROOT/install.sh" ] || ROOT=~/rr
cd "$ROOT" || exit 1
PASS=0 FAIL=0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ✓ $d"; else FAIL=$((FAIL+1)); echo "  ✗ $d"; fi; }
wait_for() { local n=$(( $1 * 2 )); shift; for ((i=0;i<n;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
STATE=~/.local/state/rex-resurrect

echo "1. Suites"
rex do tests/unit.lua | tail -1
bash tests/e2e.sh | grep -E '✗|passed'; rm -rf .t

echo "2. ./install.sh with Rex running"
rex server start >/dev/null 2>&1
check "rex server reachable" wait_for 15 rex server status
rm -rf $STATE
W=work-$$
rex new $W -c /usr --json >/dev/null
rex window new -s $W logs -c /var/log --json >/dev/null
./install.sh
check "cron @reboot entry" bash -c "crontab -l | grep -q '@reboot.*# rex-resurrect'"
check "supervisor running" bash -c "kill -0 \$(cat $STATE/supervisor.pid)"
check "first snapshot written" wait_for 20 test -s $STATE/last.json
check "snapshot has both windows" grep -q '"label":"logs"' $STATE/last.json
check "state dir 0700" test "$(stat -f %Lp $STATE)" = 700
check "palette action works" rex do resurrect_status

echo "3. Rex restarts; the supervisor brings the saver back"
lines=$(wc -l < $STATE/daemon.log)
rex server stop >/dev/null 2>&1
sleep 2
rex server start >/dev/null 2>&1
check "rex back" wait_for 15 rex server status
check "Rex restored the session itself" wait_for 10 bash -c "rex ls --json | grep -q '\"$W\"'"
check "saver re-attached (waits up to 10s + restart delay)" wait_for 60 bash -c "tail -n +$((lines + 1)) $STATE/daemon.log | grep -q 'startup:'"
rex window new -s $W after-restart -c /tmp --json >/dev/null
check "a change after the restart is saved" wait_for 20 grep -q '"label":"after-restart"' $STATE/last.json

echo "4. Re-install is idempotent"
./install.sh >/dev/null 2>&1
check "one cron entry" test "$(crontab -l | grep -c '# rex-resurrect')" = 1
# daemon(8) retitles itself "daemon: sh[pid]"; the saver is `rex do daemon.lua`.
sleep 3
check "one supervisor" test "$(pgrep -f '^daemon: .*sh\[' | wc -l | tr -d ' ')" = 1
check "one saver" wait_for 20 bash -c "test \$(pgrep -f 'do .*resurrect/daemon.lua' | wc -l) -eq 1"

echo "5. ./uninstall.sh"
./uninstall.sh >/dev/null 2>&1
sleep 1
check "cron entry gone" bash -c "! crontab -l 2>/dev/null | grep -q rex-resurrect"
check "supervisor and saver stopped" bash -c "! pgrep -f 'resurrectd.sh|daemon.lua'"
check "hook removed" bash -c "! grep -qF rex-resurrect ~/.config/rex/init.lua"
check "config still valid" rex config check
check "Rex session untouched" bash -c "rex ls --json | grep -q '\"$W\"'"
echo "--- daemon.log since restart"; tail -n +$((lines + 1)) $STATE/daemon.log | tail -n 12 | sed 's/^/   /'
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
