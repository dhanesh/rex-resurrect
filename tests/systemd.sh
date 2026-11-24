#!/bin/bash
# Real install/uninstall test on a Linux machine with systemd (e.g. a Colima VM):
#   colima ssh -p rex-test -- bash -s < tests/systemd.sh   (after copying the repo to ~/rr)
# Installs Rex's own user service, then ./install.sh, restarts Rex, checks the
# saver re-attaches, then ./uninstall.sh. Run it only on a throwaway machine.
set -u
# The checkout this script is in; piped in over stdin (bash -s), the copy at ~/rr.
ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -f "$ROOT/install.sh" ] || ROOT=~/rr
cd "$ROOT" || exit 1
PASS=0 FAIL=0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  ✓ $d"; else FAIL=$((FAIL+1)); echo "  ✗ $d"; fi; }
wait_for() { local n=$(( $1 * 2 )); shift; for ((i=0;i<n;i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 0.5; done; return 1; }
STATE=~/.local/state/rex-resurrect
export XDG_RUNTIME_DIR=/run/user/$(id -u)

echo "1. Rex server as a systemd user service"
command -v rex >/dev/null || { curl -fsSL https://pkgs.superlogical.com/rex/install.sh | sudo sh -s -- --tarball >/dev/null 2>&1; }
rex server install --user >/dev/null 2>&1 || rex server install >/dev/null 2>&1
check "rex server reachable" wait_for 15 rex server status
rm -rf $STATE  # start each run fresh
W=work-$$      # unique, so sessions Rex restored from an earlier run can't clash
rex new $W -c /usr --json >/dev/null
rex window new -s $W logs -c /var/log --json >/dev/null

echo "2. ./install.sh"
./install.sh || echo "  (install.sh exited $?)"
check "init.lua hooked" grep -qF -- '-- >>> rex-resurrect >>>' ~/.config/rex/init.lua
check "rex config check passes" rex config check
check "systemd unit active" systemctl --user is-active rex-resurrect.service
check "first snapshot written" wait_for 15 test -s $STATE/last.json
check "snapshot has both windows" grep -q '"label":"logs"' $STATE/last.json
check "state dir 0700" test "$(stat -c %a $STATE)" = 700
check "palette action works" rex do resurrect_status

echo "3. Rex restarts; the saver waits and re-attaches"
pid1=$(systemctl --user show -p MainPID --value rex-resurrect.service)
lines=$(wc -l < $STATE/daemon.log)
newlog() { tail -n +$((lines + 1)) $STATE/daemon.log; }
systemctl --user restart rex.service 2>/dev/null || { rex server stop >/dev/null 2>&1; }
check "rex back (socket activation or restart)" wait_for 20 rex server status
check "Rex restored the session itself" wait_for 10 bash -c "rex ls --json | grep -q '\"$W\"'"
check "saver still active" wait_for 30 systemctl --user is-active rex-resurrect.service
check "saver noticed the new server instance" wait_for 40 bash -c "tail -n +$((lines + 1)) $STATE/daemon.log | grep -q 'startup:'"
rex window new -s $W after-restart -c /tmp --json >/dev/null
check "a change after the restart is saved" wait_for 20 grep -q '"label":"after-restart"' $STATE/last.json
echo "   daemon pid $pid1 -> $(systemctl --user show -p MainPID --value rex-resurrect.service)"

echo "4. Re-install is idempotent"
./install.sh >/dev/null 2>&1
check "hook present exactly once" test "$(grep -cF -- '-- >>> rex-resurrect >>>' ~/.config/rex/init.lua)" = 1

echo "5. Stopping the saver is a clean stop, not a failure"
systemctl --user stop rex-resurrect.service
check "unit inactive, not failed" bash -c "[ \"\$(systemctl --user is-active rex-resurrect.service)\" = inactive ]"
systemctl --user start rex-resurrect.service
check "starts again" wait_for 15 systemctl --user is-active rex-resurrect.service

echo "6. ./uninstall.sh"
./uninstall.sh >/dev/null 2>&1
check "unit gone" bash -c "! systemctl --user cat rex-resurrect.service"
check "hook removed" bash -c "! grep -qF rex-resurrect ~/.config/rex/init.lua"
check "plugin dir removed" test ! -e ~/.config/rex/resurrect
check "config still valid" rex config check
check "snapshots kept" test -s $STATE/last.json
check "Rex session untouched" bash -c "rex ls --json | grep -q '\"$W\"'"
echo "--- daemon.log since restart"; newlog 2>/dev/null | tail -n 15 | sed 's/^/   /'
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
