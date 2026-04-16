# Troubleshooting

**"Permission denied (publickey)" on push** — your SSH key isn't set up for your memory-repo host on this machine. Add one:

- GitHub: <https://github.com/settings/keys>
- GitLab: <https://gitlab.com/-/user_settings/ssh_keys>
- Bitbucket / self-hosted: whatever your host's docs say.

**Hooks don't fire (Claude Code)** — Claude Code needs to reload them. Type `/hooks` in an active session, or start a fresh one.

**`.sync-error.log` fills up** — check `~/.hive-mind/.sync-error.log` (the hub's own log) first, then the per-adapter log (`~/.claude/.sync-error.log`). The most common cause is a push rejection from another machine having pushed first; the next turn's auto-rebase-and-retry usually fixes it. Logs are append-only — they won't be cleared unless you remove them manually. If the sync problem doesn't resolve on its own, run `git -C ~/.hive-mind pull --rebase --autostash` and `git -C ~/.hive-mind push` manually.

**I accidentally committed something sensitive** — git history is permanent. Rotate the secret, force-push a cleaned history, and consider amending the `.gitignore` to prevent recurrence.

**Per-project memory stopped syncing across machines after I renamed the repo on GitHub** — cross-machine project identity is the normalized git remote URL of `origin`, stored in `<project>/memory/.hive-mind`. After a rename, GitHub URL-redirects keep clones working, but each clone's `.git/config` still points at the old name until you run `git remote set-url`. So the two machines drift to two different `project-id` values and stop grouping. To fix:

1. On every machine that has the project, run `git -C /path/to/repo remote set-url origin <new-url>`.
2. Delete the stale sidecar on each machine: `rm ~/.claude/projects/<encoded-cwd>/memory/.hive-mind` (and the equivalent variant dir under any other attached adapter's tool root).
3. Run `~/.hive-mind/bin/sync` (or just open one of the attached tools in the project — the Stop hook regenerates the sidecar with the new URL and pushes it through the hub). Do this on every machine that has the project.

**A project has no `origin` remote (or no git remote at all)** — `mirror-projects.sh` skips it: no sidecar is written, and the variant is never grouped. To opt that project into cross-machine mirroring anyway, manually create `<project>/memory/.hive-mind` containing a single line `project-id=anything-you-want` on each machine that has the project. Use the same value on every machine. Mirror will treat them as the same project from then on.
