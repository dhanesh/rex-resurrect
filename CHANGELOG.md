# Changelog

## v0.1.1 — 2026-11-24

First public release.

* **Shell history and output (optional).** A zsh or bash hook gives each
  plain shell block its own command history and saves its recent output.
  After Rex restarts, up-arrow starts with that block's commands, and the
  old output is printed once, dimmed. Nothing is run again.
* **Clearer snapshot age.** When nothing changed for a while, the restore
  prompt now says when the snapshot was last confirmed current, not only
  when it last changed ("snapshot from Mon 00:40, still current at Mon 10:25").
* **New install methods.** `get.sh` (a one-line install from the latest
  GitHub release, checked against `SHA256SUMS`) and a Homebrew formula
  (`brew install dhanesh/tap/rex-resurrect`).
* New options: `confirm_interval`, `scrollback_lines`, `scrollback_poll`.
* MIT license.

## v0.1.0 — 2026-11-12

Initial version, not released as a download: event-driven saver, restore
prompt after a server restart, program allowlist, `install.sh` for macOS
(launchd), Linux (systemd) and FreeBSD (`daemon(8)` + cron).
