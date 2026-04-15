# Troubleshooting

**"Permission denied (publickey)" on push** — your SSH key isn't set up for your memory-repo host on this machine. Add one:

- GitHub: <https://github.com/settings/keys>
- GitLab: <https://gitlab.com/-/user_settings/ssh_keys>
- Bitbucket / self-hosted: whatever your host's docs say.

**Hooks don't fire** — Claude Code needs to reload them. Type `/hooks` in an active session, or start a fresh one.

**`.sync-error.log` fills up** — check the log; usually a push rejection from someone else pushing first. The underlying issue typically resolves on the next turn's auto-rebase-and-retry, but the log file itself is append-only — it won't be cleared unless you remove it manually. If the sync problem doesn't resolve on its own, run `git -C ~/.claude pull --rebase --autostash` and `git -C ~/.claude push` manually.

**I accidentally committed something sensitive** — git history is permanent. Rotate the secret, force-push a cleaned history, and consider amending the `.gitignore` to prevent recurrence.

**Per-project memory stopped syncing across machines after I renamed the repo on GitHub** — cross-machine project identity is the normalized git remote URL of `origin`, stored in `<project>/memory/.hive-mind`. After a rename, GitHub URL-redirects keep clones working, but each clone's `.git/config` still points at the old name until you run `git remote set-url`. So the two machines drift to two different `project-id` values and stop grouping. To fix:

1. On every machine that has the project, run `git -C /path/to/repo remote set-url origin <new-url>`.
2. Delete the stale sidecar: `rm ~/.claude/projects/<encoded-cwd>/memory/.hive-mind` on each machine.
3. Run `~/.claude/hive-mind/scripts/sync.sh` (or just open Claude Code in the project — the Stop hook regenerates the sidecar with the new URL and pushes it). Do this on every machine that has the project.

**A project has no `origin` remote (or no git remote at all)** — `mirror-projects.sh` skips it: no sidecar is written, and the variant is never grouped. To opt that project into cross-machine mirroring anyway, manually create `<project>/memory/.hive-mind` containing a single line `project-id=anything-you-want` on each machine that has the project. Use the same value on every machine. Mirror will treat them as the same project from then on.
