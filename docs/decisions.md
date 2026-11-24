# Decisions

Decisions made by the project owner, newest last.

| Date | Decision | Notes |
|---|---|---|
| 2026-11-12 | Complement Rex's native restore instead of replacing it | The plugin stays silent when Rex restored everything, and only adds what Rex skipped. |
| 2026-11-12 | Reopen programs from a safe allowlist only | Anything not on the list comes back as a shell in the right folder, and its arguments are never written to disk. |
| 2026-11-23 | Distribute through GitHub releases (`get.sh`) and a Homebrew tap | Repo `dhanesh/rex-resurrect`, tap `dhanesh/homebrew-tap`. Not yet published. |
| 2026-11-24 | Plain shell blocks get their history and output back: build both | An opt-in shell hook (zsh, bash) keeps per-block history and saves recent output, which is printed once after a restart. Unlike the snapshot, these files can contain any command's arguments and output, so they are kept only for hooked blocks (mode 0700). |
| 2026-11-24 | Fix the misleading snapshot age now | The prompt says when an unchanged snapshot was last confirmed current, not just when it last changed. |
| 2026-11-24 | Publish: public repo `dhanesh/rex-resurrect`, MIT license, first release `v0.1.1` | v0.1.0 stays an unreleased tag (its tree has no `get.sh`). Commits use the GitHub no-reply address. |
| 2026-11-24 | Make the documentation complete for anyone to install and use | README covers requirements, each install method, checking it works, updating, removing, files, and troubleshooting. |
