# rex-resurrect shell integration for zsh: per-block command history, and the
# block's output printed again after Rex restarts. Add to ~/.zshrc:
#   [[ -r ~/.config/rex/resurrect/shell/rex-resurrect.zsh ]] && source ~/.config/rex/resurrect/shell/rex-resurrect.zsh
#
# Does nothing outside Rex or in non-interactive shells. Runs no programs at
# startup; history is loaded and output replayed once, just before the first
# prompt, so where this line sits in .zshrc doesn't matter. Your normal
# history ($HISTFILE) is untouched: commands are also copied to this block's
# own file, and that file is loaded last so up-arrow reaches it first.
# Commands starting with a space are never copied.

[[ -o interactive && $REX_BLOCK == block:?* ]] || return 0
typeset -g _rr_id=${REX_BLOCK#block:}
[[ $_rr_id == *[^0-9a-f-]* ]] && return 0
typeset -g _rr_dir=${REX_RESURRECT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/rex-resurrect}/blocks/$_rr_id
[[ -d $_rr_dir ]] || command mkdir -p -m 700 -- "$_rr_dir" 2>/dev/null || return 0
# This file existing is what tells the saver to keep this block's output.
{ : >>| "$_rr_dir/history" } 2>/dev/null || return 0

_rr_addhistory() {
  emulate -L zsh
  local nl=$'\n' line=${1%%$'\n'}
  if [[ -n $line && $line != ' '* ]]; then
    # zsh's history file format: a newline inside a command is "\" + newline.
    print -r -- "${line//$nl/\\$nl}" >>| "$_rr_dir/history" 2>/dev/null
  fi
  return 0  # never stop zsh from saving the command to its own history
}

_rr_replay() {
  emulate -L zsh
  local f=$1 tag epoch when body nl=$'\n'
  { IFS=' ' read -r tag epoch when <"$f" } 2>/dev/null
  [[ $tag == rex-resurrect-scrollback ]] || return 0
  body=$(<"$f")
  print -r -- $'\e[2m'"── output from before Rex restarted · saved ${when} ──"
  print -r -- "${body#*$nl}"
  print -r -- "── end of restored output ──"$'\e[0m'
}

_rr_first_prompt() {
  emulate -L zsh
  add-zsh-hook -d precmd _rr_first_prompt
  local d=$_rr_dir sock
  if [[ -s $d/history ]]; then
    local -a lines
    lines=("${(@f)$(<$d/history)}")
    if (( $#lines > 2000 )); then print -rl -- "${(@)lines[-1000,-1]}" >| $d/history; fi
    fc -R -- $d/history
  fi
  # Output saved before this server started: Rex restored this block.
  if [[ -s $d/scrollback && $REX_SERVER == unix://* ]]; then
    printf -v sock '%b' "${${REX_SERVER#unix://}//\%/\\x}"
    if [[ -S $sock && $d/scrollback -ot $sock ]]; then
      command mv -f -- $d/scrollback $d/scrollback.shown 2>/dev/null && { _rr_replay $d/scrollback.shown; command rm -f -- $d/scrollback.shown }
    fi
  fi
  return 0
}

# Files handed over by a restore that rebuilt this block under a new id. They
# can arrive after the first prompt, so every prompt looks (two file tests).
_rr_pickup() {
  emulate -L zsh
  local d=$_rr_dir nl=$'\n' old cur
  if [[ -f $d/history.restore ]]; then
    old=$(<$d/history.restore)
    [[ -s $d/history ]] && cur=$(<$d/history)
    print -r -- "$old${cur:+$nl$cur}" >| $d/history
    fc -R -- $d/history.restore
    command rm -f -- $d/history.restore
  fi
  if [[ -s $d/scrollback.restore ]]; then
    command mv -f -- $d/scrollback.restore $d/scrollback.shown 2>/dev/null && { _rr_replay $d/scrollback.shown; command rm -f -- $d/scrollback.shown }
  fi
  return 0
}
_rr_precmd() {
  [[ -e $_rr_dir/history.restore || -e $_rr_dir/scrollback.restore ]] && _rr_pickup
  return 0
}

autoload -Uz add-zsh-hook
add-zsh-hook zshaddhistory _rr_addhistory
add-zsh-hook precmd _rr_first_prompt
add-zsh-hook precmd _rr_precmd
