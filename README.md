# rex-resurrect

tmux-resurrect for [Rex](https://superlogical.com). It keeps a snapshot of your
sessions, windows, panes, the folder each pane is in, and the program running
in it. After the Rex server restarts, it offers to bring back whatever Rex
didn't restore itself.

## How it fits with Rex's own restore

Rex already restores sessions after a clean restart. rex-resurrect fills the
gaps instead of competing with it:

| After a restart…                                            | rex-resurrect            |
|-------------------------------------------------------------|--------------------------|
| Rex restored everything, and no program needs reopening     | stays silent             |
| Rex skipped sessions (crash, upgrade, `--restore=false`, …) | offers to rebuild them   |
| Panes came back as bare shells but were running `nvim`, `less`, `claude`… | offers to reopen those programs |

It never closes, replaces or duplicates anything. Restoring only adds.

```
rex-resurrect · snapshot from Thu 13:14 (12 min ago)

Rex brought back 1 of 2 saved sessions on its own.

Not restored yet:
  • api-work             3 windows, 5 panes  ~/code/api, ~/code/api/web

Programs to reopen:
  • dusty-moor / editor          nvim main.go  (~/code/x)

Restore now? [Y/n]
```

The prompt opens as a floating pane. Answering `n`, or closing the pane, puts
the snapshot in history and doesn't ask about it again.

## Install

```sh
./install.sh            # copies to ~/.config/rex/resurrect, hooks init.lua, starts the saver
./install.sh --link     # symlink instead, for hacking on it
./uninstall.sh [--purge]
```

The installer backs up `init.lua`, adds a single `pcall`-guarded line, checks
the result with `rex config check`, and rolls back if that fails. The saver
runs as a background service that **never starts a Rex server**; it waits
until one is running:

| Platform | Saver runs as                                                   | Tested on |
|----------|-----------------------------------------------------------------|-----------|
| macOS    | launchd agent `dev.rex-resurrect`                               | macOS (arm64), Rex preview.14 |
| Linux    | systemd user service `rex-resurrect`                            | Ubuntu 24.04 VM (systemd), Ubuntu 24.04 and Alpine 3.22 (musl) containers |
| FreeBSD  | `daemon(8)`, which restarts it, started at boot by cron `@reboot` | FreeBSD 15.1 (arm64) VM, including a reboot |

Windows isn't supported: Rex's Windows server isn't in public testing yet.

## Use

| What                         | How                                                              |
|------------------------------|------------------------------------------------------------------|
| Save now                     | palette: **Resurrect: Save Now** · `rex do resurrect_save`       |
| Restore                      | palette: **Resurrect: Restore Saved Sessions** · `rex do resurrect_restore` |
| Restore an older snapshot    | `rex do resurrect_restore from=history` (newest archived) or `from=<file name>` |
| Status                       | `rex do resurrect_status`                                        |

Bind a key in `init.lua` if you like: `rex.bind("ctrl+shift+s", "resurrect_save")`.

## What triggers a save

* Any structural change: session created, closed or moved; window or pane
  created, closed, split, moved or renamed (`session_view_changed`).
* A pane's folder or foreground program changing (`pwd_changed`, `process_changed`).
* A full re-read every 5 minutes, as a safety net.

Saves are throttled (at most one every 5 s). Only the sessions and panes an
event touched are re-read, and the file is written only when its content
actually changed. Under a pane spawning processes nonstop, the saver used
about 0.02 s of CPU in 20 s. An idle server causes no disk writes.

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
  folder, and its arguments are never written to disk.
* **Typed, not executed.** A program is typed into an idle shell with each word
  shell-quoted, the way tmux-resurrect does it. Quitting the program leaves
  you at a shell.
* **Smart reopen.** `claude` reopens as `claude --continue`, `codex` as
  `codex resume --last`, `tail` only with `-f`, and `vim`/`nvim` use
  `Session.vim` when there is one.

## Configure

Optional: `~/.config/rex/resurrect-config.lua`

```lua
return {
  on_restart = "ask",          -- "ask" | "auto" (restore silently) | "off"
  restore_programs = true,
  extra_programs = { "ssh" },  -- add to the allowlist
  exclude_programs = { "claude" },
  strategies = {               -- argv to reopen with, or false to never reopen
    ssh = function(argv, cwd) return argv end,
  },
  min_save_interval = 5,       -- seconds; clamped to sane ranges
  resync_interval = 300,
  history_keep = 20,
}
```

Bad values are ignored, with a warning in the log, rather than breaking saving.

## Limits

* Floating panes aren't saved; only the tiled layout of each window is.
* On macOS, `ps` joins arguments with spaces, so a reopened program gets an
  argument containing a space split into two words. Linux reads
  `/proc/<pid>/cmdline` and is exact.
* Scrollback isn't saved or restored by the plugin. Sessions the plugin
  rebuilds start with empty panes.

## Develop

```sh
rex do tests/unit.lua   # unit tests, in Rex's own Lua 5.1 runtime
tests/e2e.sh            # full lifecycle against a throwaway server (never yours)
tests/linux.sh          # both of the above in Ubuntu and Alpine containers (docker/Colima)
```

On a throwaway machine only, since they restart its Rex server:
`tests/systemd.sh` (Linux, e.g. a Colima VM) and `tests/freebsd.sh` (e.g. a
Lima `template://freebsd` VM) run a real install, a Rex restart and an
uninstall.

Layout: `resurrect/daemon.lua` (event-driven saver), `snapshot.lua` (capture),
`plan.lua` (diff saved vs. live), `restore.lua`, `programs.lua` (allowlist and
strategies), `store.lua` (atomic files), `commands.lua` (shared by the daemon,
`ctl.lua` and the palette actions in `actions.lua`).

Notes on the Rex Lua runtime (preview.14) that shaped the code:

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
