# rex-resurrect shell integration for bash: per-block command history, and
# the block's output printed again after Rex restarts. Add to ~/.bashrc:
#   [ -r ~/.config/rex/resurrect/shell/rex-resurrect.bash ] && . ~/.config/rex/resurrect/shell/rex-resurrect.bash
#
# Does nothing outside Rex or in non-interactive shells. Your normal history
# is untouched: commands are also copied to this block's own file, which is
# loaded at the first prompt so up-arrow reaches it first. Commands starting
# with a space, and multi-line commands, are not copied.

[[ $- == *i* && ${REX_BLOCK:-} == block:?* ]] || return 0
[[ ${PROMPT_COMMAND:-} == *_rr_prompt* ]] && return 0
_rr_id=${REX_BLOCK#block:}
[[ $_rr_id == *[!0-9a-f-]* ]] && return 0
_rr_dir=${REX_RESURRECT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/rex-resurrect}/blocks/$_rr_id
[[ -d $_rr_dir ]] || mkdir -p -m 700 "$_rr_dir" 2>/dev/null || return 0
# This file existing is what tells the saver to keep this block's output.
{ : >> "$_rr_dir/history"; } 2>/dev/null || return 0

_rr_replay() {
  local f=$1 tag epoch when
  IFS=' ' read -r tag epoch when <"$f" 2>/dev/null
  [[ $tag == rex-resurrect-scrollback ]] || return 0
  printf '\033[2m── output from before Rex restarted · saved %s ──\n' "$when"
  { read -r _; cat; } <"$f"
  printf '── end of restored output ──\033[0m\n'
}

_rr_first() {
  local d=$_rr_dir sock p
  if [[ -s $d/history ]]; then
    if (( $(wc -l <"$d/history") > 2000 )); then
      tail -n 1000 "$d/history" >"$d/history.tmp" && mv -f "$d/history.tmp" "$d/history"
    fi
    history -r "$d/history"
  fi
  # Output saved before this server started: Rex restored this block.
  if [[ -s $d/scrollback && ${REX_SERVER:-} == unix://* ]]; then
    p=${REX_SERVER#unix://}
    printf -v sock '%b' "${p//\%/\\x}"
    if [[ -S $sock && $d/scrollback -ot $sock ]]; then
      mv -f "$d/scrollback" "$d/scrollback.shown" 2>/dev/null && { _rr_replay "$d/scrollback.shown"; rm -f "$d/scrollback.shown"; }
    fi
  fi
}

# Files handed over by a restore that rebuilt this block under a new id. They
# can arrive after the first prompt, so every prompt looks (two file tests).
_rr_pickup() {
  local d=$_rr_dir
  if [[ -f $d/history.restore ]]; then
    { cat "$d/history.restore"; cat "$d/history" 2>/dev/null; } >"$d/history.tmp" && mv -f "$d/history.tmp" "$d/history"
    history -r "$d/history.restore"
    rm -f "$d/history.restore"
  fi
  if [[ -s $d/scrollback.restore ]]; then
    mv -f "$d/scrollback.restore" "$d/scrollback.shown" 2>/dev/null && { _rr_replay "$d/scrollback.shown"; rm -f "$d/scrollback.shown"; }
  fi
}

# The number of the newest history entry, so that only commands typed after
# it are copied (not ones loaded from files).
_rr_sync() {
  _rr_num=$(HISTTIMEFORMAT= builtin history 1); _rr_num=${_rr_num#"${_rr_num%%[! ]*}"}; _rr_num=${_rr_num%%[!0-9]*}
}

_rr_record() {
  local line num
  line=$(HISTTIMEFORMAT= builtin history 1)
  line=${line#"${line%%[! ]*}"}
  num=${line%%[!0-9]*}
  if [[ -n $num && $num != "${_rr_num:-}" ]]; then
    _rr_num=$num
    line=${line#"$num"}; line=${line#\*}; line=${line#  }
    if [[ -n $line && $line != ' '* && $line != *$'\n'* ]]; then
      printf '%s\n' "$line" >>"$_rr_dir/history" 2>/dev/null
    fi
  fi
}

_rr_prompt() {
  local rc=$?
  if [[ -n ${_rr_started:-} ]]; then _rr_record; else _rr_started=1; _rr_first; _rr_sync; fi
  if [[ -e $_rr_dir/history.restore || -e $_rr_dir/scrollback.restore ]]; then _rr_pickup; _rr_sync; fi
  return $rc
}

PROMPT_COMMAND="_rr_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
