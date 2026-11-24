#!/bin/sh
# Shown in a floating pane after a server restart when something can be restored.
# usage: prompt.sh REX_BIN CTL_LUA SUMMARY_FILE [SERVER]
REX=$1 CTL=$2 SUMMARY=$3 SERVER=$4

rexc() {
  if [ -n "$SERVER" ]; then "$REX" -S "$SERVER" --autostart=false "$@"
  else "$REX" --autostart=false "$@"; fi
}

answered=0
dismiss() {
  [ "$answered" = 1 ] && return
  answered=1
  rexc do "$CTL" cmd=dismiss >/dev/null 2>&1
}
# Closing the pane counts as "no", so the question is never asked twice.
trap 'dismiss; exit 0' HUP INT TERM

printf '\n'
cat "$SUMMARY" 2>/dev/null || echo "rex-resurrect: saved sessions can be restored."
printf '\nRestore now? [Y/n] '
if ! read -r answer; then dismiss; exit 0; fi

case $answer in
  [nN]*)
    dismiss
    printf 'Skipped. To restore later: rex do resurrect_restore from=history\n'
    sleep 2
    exit 0 ;;
esac

answered=1
printf '\nRestoring…\n'
if rexc do "$CTL" cmd=restore; then
  sleep 1.5
else
  printf '\nSome items could not be restored (see above). Press Enter to close. '
  read -r _
fi
