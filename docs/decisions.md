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
| 2026-11-24 | Verify what v0.1.1 left unverified (own zsh config, Homebrew on macOS and Linux, `brew audit`), fix what that finds, and send the fixes as a pull request | Fixes go to v0.1.2, released after the PR is merged. |
| 2026-11-24 | Verify the two items left unverified: `brew upgrade` from v0.1.1, and `brew services` starting the saver at login | Done before release, without publishing: a locally built v0.1.2 archive stands in for the release, in a throwaway VM and on the Mac (restored afterwards). Login: a PAM login session in the VM with linger off, and launchd's bootstrap of the agent on the Mac. |
| 2026-11-24 | PR #1 merged: release v0.1.2 and update the tap | Released from `main`; `brew upgrade` from v0.1.1 and the one-line install were checked against the published release. |
