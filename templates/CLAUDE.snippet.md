## Memory-commit convention

When you write or edit `~/.claude/CLAUDE.md` or any file under
`~/.claude/projects/*/memory/`, also write a single imperative-mood sentence
(≤80 chars, no trailing period) to `~/.claude/.commit-msg` describing *what*
changed. The hive-mind sync script reads that file as the commit message
and deletes it.

Examples:
- `add PowerShell-on-Windows shell preference to global notes`
- `note service X IAM grant for cross-project bucket read`
- `dedupe CLAUDE.md — 2 duplicate lines from union merge`

If you don't write one, sync falls back to a basename-only summary
(e.g. `update CLAUDE.md`). Always prefer to write one — future-you grepping
`git log` will thank you.
