---
name: memory-commit
description: Editing or writing Claude's memory files — `~/.claude/CLAUDE.md` or anything under `~/.claude/projects/*/memory/`. **Load this skill any time you are about to remember something, save a user preference, update a project memory, add feedback memory, or touch any file in those paths.** The skill tells you to also write a one-line commit summary to `~/.claude/.commit-msg` so the memory-sync git history is meaningful.
---

# Memory-commit convention

## When to use

Any time you write or edit:
- `~/.claude/CLAUDE.md` (global user instructions)
- Any file under `~/.claude/projects/*/memory/` (per-project auto-memory)

i.e. when the user asks you to "remember", "save", "note", update/add a preference, feedback, or project memory — *before* you touch the file itself, follow the steps below.

## Why

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
