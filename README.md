# rex-resurrect

Session save and restore for [Rex](https://superlogical.com), in the spirit
of tmux-resurrect. It keeps a snapshot of your sessions, windows, panes, the
folder each pane is in, and the program running in it. After the Rex server
restarts — a crash, a reboot, an upgrade — it offers to bring back whatever
Rex didn't restore by itself.

```
rex-resurrect · snapshot from Thu 13:14 (12 min ago)

Rex brought back 1 of 2 saved sessions on its own.

Not restored yet:
  • api-work             3 windows, 5 panes  ~/code/api, ~/code/api/web

Programs to reopen:
  • notes / editor               nvim main.go  (~/code/x)

Restore now? [Y/n]
```

With the optional [shell hook](#shell-history-and-output-optional), plain
shell panes also get their own command history and their recent output back.

**Contents:** [Requirements](#requirements) ·
[Install](#install) · [Check that it works](#check-that-it-works) ·
[Use](#use) · [Shell history and output](#shell-history-and-output-optional) ·
[Configure](#configure) · [Update](#update) · [Uninstall](#uninstall) ·
[Files](#files) · [Troubleshooting](#troubleshooting) ·
[How it works](#how-it-works) · [Safety](#safety) · [Limits](#limits) ·
[Develop](#develop) · [License](#license)

## Requirements

* **Rex** with its `rex` command on your `PATH`. Tested with Rex
  0.1.0-preview.14 to preview.22.
* **macOS, Linux or FreeBSD.** Windows isn't supported, because Rex's Windows
  server isn't in public testing yet.
* For the one-line install: `curl` (or `fetch` on FreeBSD), `tar`, and
  `sha256sum` or `shasum`. A standard system has all of them.
* For the optional shell hook: zsh or bash.

No install method needs root.

## Install

Pick one of the three methods. Each one:

1. Puts the plugin in `~/.config/rex/resurrect`.
2. Adds one guarded block to `~/.config/rex/init.lua` (backed up first).
3. Starts a small background **saver**. It never starts a Rex server itself;
   it waits until one is running.

### One line (macOS, Linux, FreeBSD)

```sh
curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh | sh
```

On FreeBSD, use `fetch -o - <same url> | sh`.

This downloads the latest release, checks it against the release's
`SHA256SUMS`, runs the installer, and deletes the download. Options go after
`sh -s --`, for example `… | sh -s -- --version v0.1.1`:

| Option             | Effect                                                        |
|--------------------|---------------------------------------------------------------|
| `--version v0.1.1` | install that release instead of the latest                    |
| `--no-service`     | don't install the background saver (run it yourself)         |
| `--uninstall`      | remove rex-resurrect; add `--purge` to delete saved snapshots |

### Homebrew (macOS, Linux)

```sh
brew install dhanesh/tap/rex-resurrect
rex-resurrect setup                    # once per user: hook init.lua, link the plugin
brew services start rex-resurrect      # run the saver now and at login
```

`rex-resurrect setup` also stops a saver left by an earlier one-line or
checkout install on macOS, so only one ever runs. On Linux, `brew services`
runs the saver as a systemd user service; don't also install it with the
one-line install.

### From a checkout

```sh
git clone https://github.com/dhanesh/rex-resurrect
cd rex-resurrect
./install.sh              # copy the plugin, hook init.lua, start the saver
./install.sh --link       # symlink instead of copy, to hack on the plugin
./install.sh --no-service # don't install the saver service
```

### Where the saver runs

| Platform | Saver runs as                                              | Tested on |
|----------|------------------------------------------------------------|-----------|
| macOS    | launchd agent `dev.rex-resurrect` (or `brew services`)      | macOS (arm64), including Homebrew |
| Linux    | systemd user service `rex-resurrect` (or `brew services`)   | Ubuntu 24.04 VM (systemd), including Homebrew; Ubuntu 24.04 and Alpine 3.22 (musl) containers |
| FreeBSD  | `daemon(8)`, which restarts it, started at boot by cron `@reboot` | FreeBSD 15.1 (arm64) VM, including a reboot |

The installer checks `init.lua` with `rex config check` before and after
changing it, and puts the backup back if the change would break it.

## Check that it works

```sh
rex do resurrect_status
```

prints what was saved and when, for example:

```json
{"sessions":1,"windows":7,"panes":9,"saved":"2 min ago","on_restart":"ask","pending":false,"history":20, …}
```

If `sessions` is 0 or `saved` is missing, see
[Troubleshooting](#troubleshooting). The saver logs to
`~/.local/state/rex-resurrect/daemon.log`.

The real test is a restart: stop Rex's server (for example with
`rex server stop`) and start Rex again. If there is anything to restore, the
prompt appears as a floating pane. If Rex brought everything back by itself,
rex-resurrect stays silent.

## Use

Saving is automatic, and after a restart the prompt asks before restoring
anything. Answering `n`, or closing the prompt, archives that snapshot and
doesn't ask about it again.

| What                         | How                                                              |
|------------------------------|------------------------------------------------------------------|
| Save now                     | palette: **Resurrect: Save Now** · `rex do resurrect_save`       |
| Restore                      | palette: **Resurrect: Restore Saved Sessions** · `rex do resurrect_restore` |
| Restore an older snapshot    | `rex do resurrect_restore from=history` (newest archived) or `from=<file name>` |
| Status                       | palette: **Resurrect: Status** · `rex do resurrect_status`       |

With Homebrew, `rex-resurrect status` does the same as `rex do resurrect_status`.

Bind a key in `init.lua` if you like: `rex.bind("ctrl+shift+s", "resurrect_save")`.

### How it fits with Rex's own restore

Rex already restores sessions after a clean restart. rex-resurrect fills the
gaps instead of competing with it:

| After a restart…                                            | rex-resurrect            |
|-------------------------------------------------------------|--------------------------|
| Rex restored everything, and no program needs reopening     | stays silent             |
| Rex skipped sessions (crash, upgrade, `--restore=false`, …) | offers to rebuild them   |
| Panes came back as bare shells but were running `nvim`, `less`, `claude`… | offers to reopen those programs |

It never closes, replaces or duplicates anything. Restoring only adds.

## Shell history and output (optional)

Rex brings plain shell panes back in the right folder, but empty: no output,
and up-arrow shows your whole shell history rather than that pane's. A small
shell hook fixes both. Add one line to your shell's startup file (the
installer prints the right one for your shell). It works with every install
method:

```sh
# ~/.zshrc
[ -r ~/.config/rex/resurrect/shell/rex-resurrect.zsh ] && . ~/.config/rex/resurrect/shell/rex-resurrect.zsh
# ~/.bashrc
[ -r ~/.config/rex/resurrect/shell/rex-resurrect.bash ] && . ~/.config/rex/resurrect/shell/rex-resurrect.bash
```

It applies to shells opened afterwards, and you see the effect after the next
Rex restart. Shells in Rex then get:

* **Their own history.** Each command is also copied to that pane's file.
  After a restart, up-arrow starts with that pane's own recent commands.
  With zsh's `share_history`, commands run later in other panes still show
  up too, as before. Your normal history file is unchanged, with no
  duplicates.
* **Their output back.** The saver keeps the last 2,000 lines of each hooked
  pane's output. After Rex restarts, the shell prints them once, dimmed,
  under an "output from before Rex restarted" line. A nested shell, or
  `exec zsh`, doesn't print them again.

What it doesn't do:

* **Nothing is run again.** Old output is only printed, and old commands only
  appear in history.
* **Some commands aren't copied.** Commands starting with a space are never
  copied; in bash, neither are multi-line commands.
* **Output is plain text.** Colours and escape sequences are dropped, so
  replaying can't change your title, clipboard or terminal modes.
* **Some screens aren't saved.** Editors, pagers and other full-screen
  programs are skipped.
* **Output is saved shortly after each command,** within 15 s. A command that
  is still running is re-read every 5 minutes.

**Privacy.** Saved output can contain whatever your commands printed,
including secrets and command lines typed with a leading space. Printed
output is deleted once it has been shown. It is stored only for panes with
the hook, in `~/.local/state/rex-resurrect/blocks/` (mode 0700). Files of
closed panes are deleted after a day, unless a saved snapshot could still
restore that pane. Set `scrollback_lines = 0` to keep history only. The hook
does nothing outside Rex or in non-interactive shells, and starts no programs
when a shell opens.

To turn it off, remove the line from your startup file.

## Configure

Optional: create `~/.config/rex/resurrect-config.lua`. Every key is optional;
the values below are the defaults, except the examples in the lists:

```lua
return {
  on_restart = "ask",          -- "ask" | "auto" (restore silently) | "off"
  restore_programs = true,     -- reopen allowlisted programs
  extra_programs = { "ssh" },  -- add to the allowlist (default: none)
  exclude_programs = { "claude" }, -- remove from it (default: none)
  strategies = {               -- argv to reopen with, or false to never reopen
    ssh = function(argv, cwd) return argv end,
  },
  min_save_interval = 5,       -- seconds between saves, at least
  resync_interval = 300,       -- full re-read, as a safety net
  history_keep = 20,           -- archived snapshots kept
  confirm_interval = 900,      -- note "snapshot still current" at most this often
  scrollback_lines = 2000,     -- output kept per hooked pane; 0 = history only
  scrollback_poll = 15,        -- look for commands run in hooked panes this often
}
```

Numbers are clamped to sane ranges. A bad value is ignored, with a warning in
the log, rather than breaking saving. The saver reads this file when it
starts, so restart it after a change (the command for your platform is under
[Troubleshooting](#troubleshooting)).

## Update

| Installed with   | Update with |
|------------------|-------------|
| one-line install | run the same `curl … \| sh` again |
| Homebrew         | `brew upgrade rex-resurrect && brew services restart rex-resurrect` |
| a checkout       | `git pull && ./install.sh` (add `--link` if you used it) |

Saved snapshots and settings are kept. The installer restarts the saver.

## Uninstall

| Installed with   | Remove with |
|------------------|-------------|
| one-line install | `curl -fsSL https://raw.githubusercontent.com/dhanesh/rex-resurrect/main/get.sh \| sh -s -- --uninstall` |
| Homebrew         | `rex-resurrect remove`, `brew services stop rex-resurrect`, then `brew uninstall rex-resurrect` |
| a checkout       | `./uninstall.sh` |

Uninstalling stops the saver, removes the plugin and its block from
`init.lua`, and keeps your snapshots. Add `--purge` (after `--uninstall`, or
to `./uninstall.sh`) to delete them too, or delete
`~/.local/state/rex-resurrect` yourself. If you added the shell hook line,
remove it from your startup file.

## Files

| Path | What |
|------|------|
| `~/.config/rex/resurrect/` | the plugin (a symlink with Homebrew or `--link`) |
| `~/.config/rex/init.lua` | gets one block between `-- >>> rex-resurrect >>>` markers |
| `~/.config/rex/resurrect-config.lua` | your settings, if you create it |
| `~/.local/state/rex-resurrect/last.json` | the current snapshot |
| `~/.local/state/rex-resurrect/pending.json` | the snapshot from before a restart, until you answer the prompt |
| `~/.local/state/rex-resurrect/history/` | archived snapshots |
| `~/.local/state/rex-resurrect/blocks/` | per-pane history and output (shell hook only) |
| `~/.local/state/rex-resurrect/daemon.log` | the saver's log, size-capped |

`XDG_CONFIG_HOME` and `XDG_STATE_HOME` are respected. The saver service is
`~/Library/LaunchAgents/dev.rex-resurrect.plist` on macOS,
`~/.config/systemd/user/rex-resurrect.service` on Linux, and a
`# rex-resurrect` line in your crontab on FreeBSD.

## Troubleshooting

**Is the saver running?**

| Platform        | Check | Restart |
|-----------------|-------|---------|
| macOS           | `launchctl print gui/$(id -u)/dev.rex-resurrect \| grep state` | `launchctl kickstart -k gui/$(id -u)/dev.rex-resurrect` |
| Homebrew        | `brew services info rex-resurrect` | `brew services restart rex-resurrect` |
| Linux           | `systemctl --user status rex-resurrect` | `systemctl --user restart rex-resurrect` |
| FreeBSD         | `pgrep -f resurrectd.sh` | run the installer again |

Then look at the end of `~/.local/state/rex-resurrect/daemon.log`. A healthy
saver logs `saving to … (every change, …)` once Rex is running.

**No prompt after a restart.** That's expected when Rex restored every
session and no program needs reopening. Otherwise, check that the saver is
running, and that `rex do resurrect_status` listed your sessions before the
restart. `on_restart = "off"` turns the prompt off.

**`rex do resurrect_status` fails or the palette has no Resurrect actions.**
Rex hasn't loaded the plugin. Run `rex config check`, then
`rex config reload`, and check that `~/.config/rex/init.lua` contains the
`-- >>> rex-resurrect >>>` block.

**The shell hook does nothing.** It only runs in shells started inside Rex
after you added the line. Open a new pane and check that
`~/.local/state/rex-resurrect/blocks/` gets a new folder. Old output appears
only after the Rex server restarts.

**Linux: the hook line is in `~/.zshrc`, but Rex starts bash.** Rex on Linux
starts your login shell from `/etc/passwd`, not `$SHELL`. Change it with
`chsh -s "$(command -v zsh)"`.

**A program came back as a plain shell.** Only programs on the allowlist are
reopened (see [Safety](#safety)). Add one with `extra_programs`.

## How it works

What triggers a save:

* Any structural change: session created, closed or moved; window or pane
  created, closed, split, moved or renamed (`session_view_changed`).
* A pane's folder or foreground program changing (`pwd_changed`, `process_changed`).
* A full re-read every 5 minutes, as a safety net.

Saves are throttled (at most one every 5 s). Only the sessions and panes an
event touched are re-read, and the snapshot is rewritten only when its content
actually changed. Under a pane spawning processes nonstop, the saver used
about 0.02 s of CPU in 20 s. On an idle server, the only disk write is a tiny
`checked.json` every 15 minutes. It records that the snapshot is still
current, so the restore prompt can say "snapshot from Mon 00:40, still
current at Mon 10:25" instead of only showing when it last changed.

## Safety

* **Atomic writes.** Each save goes to a temporary file that is renamed over
  the old one. State lives in `~/.local/state/rex-resurrect` (mode 0700).
* **No clobbering.** The snapshot from before a restart is frozen as
  `pending.json` before anything new is saved. An empty capture never
  replaces a saved one. Closing a session archives the previous snapshot,
  so a session closed by accident can be restored with `from=history`.
* **Programs: allowlist only.** Only these are recorded with their arguments
  and reopened: `vi vim nvim nano micro hx helix kak emacs less more man tail
  top htop btop glances lazygit tig k9s yazi ranger nnn lf claude codex`.
  Anything else (`make deploy`, `mysql -p…`) comes back as a shell in the right
  folder, and the saver never writes its arguments to disk. The exception is
  the optional [shell hook](#shell-history-and-output-optional): it keeps
  each hooked pane's command history and output, which can include them.
* **Typed, not executed.** A program is typed into an idle shell with each word
  shell-quoted, the way tmux-resurrect does it. Quitting the program leaves
  you at a shell.
* **Smart reopen.** `claude` reopens as `claude --continue`, `codex` as
  `codex resume --last`, `tail` only with `-f`, and `vim`/`nvim` use
  `Session.vim` when there is one.
* **Can't break your config.** The `init.lua` line is wrapped in `pcall`, so
  a problem in the plugin never stops the rest of your config from loading.

## Limits

* Floating panes aren't saved; only the tiled layout of each window is.
* On macOS, `ps` joins arguments with spaces, so a reopened program gets an
  argument containing a space split into two words. Linux reads
  `/proc/<pid>/cmdline` and is exact.
* Without the shell hook, output isn't saved: restored panes start empty.
  With it, output comes back as plain text, and only for shells started after
  the hook was added.
* The shell hook supports zsh and bash. Other shells get folders and
  programs back, but not history or output.

## Develop

```sh
rex do tests/unit.lua   # unit tests, in Rex's own Lua 5.1 runtime
tests/e2e.sh            # full lifecycle against a throwaway server (never yours)
tests/get-test.sh       # get.sh against a local release copy, sandboxed, no service
tests/shell-e2e.sh      # the zsh hook through two restarts, on a throwaway server and zsh
RR_TEST_RC=~/.zshrc tests/shell-e2e.sh   # the same, after your own zsh config (read only)
tests/linux.sh          # all of the above in Ubuntu and Alpine containers, plus the bash hook
```

On a throwaway machine only, since they install services or restart its Rex
server: `tests/systemd.sh` (Linux, e.g. a Colima VM) and `tests/freebsd.sh`
(e.g. a Lima `template://freebsd` VM) run a real install, a Rex restart and an
uninstall; `tests/get-test.sh --service` does the same through `get.sh`.

### Releasing

```sh
git tag -a v0.2.0 -m "rex-resurrect v0.2.0"
git push origin main v0.2.0
tools/release.sh v0.2.0 --publish   # builds dist/v0.2.0/ and creates the GitHub release (gh)
```

`get.sh` reads `releases/latest/download/rex-resurrect.tar.gz`, so the archive
name never changes. Copy `dist/<tag>/rex-resurrect.rb` to the tap repo
(`dhanesh/homebrew-tap`, `Formula/rex-resurrect.rb`), and note the release in
`CHANGELOG.md`.

Layout: `resurrect/daemon.lua` (event-driven saver), `snapshot.lua` (capture),
`plan.lua` (diff saved vs. live), `restore.lua`, `programs.lua` (allowlist and
strategies), `store.lua` (atomic files), `scrollback.lua` (output of hooked
panes), `shell/` (the zsh and bash hooks), `commands.lua` (shared by the
daemon, `ctl.lua` and the palette actions in `actions.lua`). Decisions are
logged in `docs/decisions.md`.

Notes on the Rex Lua runtime that shaped the code:

* `rex.on` in `init.lua` doesn't run yet, and `init.lua` has no timers. The
  saver is therefore a `rex do --all` script, supervised by launchd or systemd.
* `rex.call` returns `nil, err` instead of raising. Session-scoped methods
  need the connection attached to the session; `util.call` attaches on demand.
* GopherLua quirk: after a Lua error is caught by `pcall`, a local that
  closures assign to can become detached from its enclosing function. Shared
  mutable state is kept in tables for this reason.
* `rex do` targets `$REX_BLOCK`, so a script started inside a pane fails on a
  server with no sessions. The service wrapper unsets it.
* `os.date("%a")` always returns `mon`; `util.short_time` cuts the weekday
  from `%A`, which is correct.
* Rex sends no event for a quick command (`echo`, `ls`), and ignores `env`
  on new blocks. The saver notices commands by the hook's history file
  growing. For a session it rebuilds, it moves each old block's files to the
  new block's id. Rex keeps block ids across its own restore, so
  those blocks need no move.
* On Linux, Rex starts the account's login shell from `/etc/passwd`, not
  `$SHELL`. On macOS it starts shells through `login(1)`, which resets `HOME`.

## License

[MIT](LICENSE)
