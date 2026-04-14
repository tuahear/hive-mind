---
name: memory-commit
description: Writing a one-line commit message for a memory update. Use whenever you are about to write or edit `~/.claude/CLAUDE.md` or any file under `~/.claude/projects/*/memory/` — i.e. when you're saving a user preference, project fact, feedback memory, or any auto-memory record. Ensures the resulting git commit in the memory repo has a meaningful summary instead of a generic "update file.md" fallback.
---

# Memory-commit convention

The hive-mind sync script (`~/.claude/hive-mind/scripts/sync.sh`, wired to the `Stop` hook) reads `~/.claude/.commit-msg` to pick up a commit message you supplied for the memory change you're about to make.

## What to do

Right before (or right after) you write/edit a memory file — CLAUDE.md or anything under `~/.claude/projects/*/memory/` — write **one imperative-mood sentence** (≤80 chars, no trailing period) to `~/.claude/.commit-msg` describing *what* changed.

sync.sh consumes the file (reads it, uses as commit message, deletes it) on the next turn-end.

## Format

- Imperative mood: "add X", "note Y", "dedupe Z"
- ≤80 chars
- No trailing period
- Describe the change, not the mechanism

## Fallback

If you skip this step, sync.sh falls back to a basename summary (`update CLAUDE.md`). Still functional but loses context — future-you grepping `git log` will prefer the meaningful message.
