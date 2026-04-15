---
name: memory-commit
description: Editing or writing any of Claude's hive-mind-synced files — `~/.claude/CLAUDE.md`, anything under `~/.claude/projects/*/memory/`, `~/.claude/projects/*/MEMORY.md` (index), or anything under `~/.claude/skills/*/`. **Load this skill any time you are about to remember something, save a user preference, update a project memory, update a project MEMORY index, add feedback memory, create or modify a skill, or touch any file in those paths.** Embed a one-line commit-summary marker inside the edit; the hive-mind sync script extracts it, strips it from the file, and uses it as the git commit message.
---

# Memory-commit convention

## When to use

Any time you write or edit:
- `~/.claude/CLAUDE.md`
- `~/.claude/projects/*/MEMORY.md` (per-project memory index)
- Any file under `~/.claude/projects/*/memory/`
- Any file under `~/.claude/skills/*/` (SKILL.md, scripts, resources)

## What to do

Embed a single HTML comment **inside the same edit**, on its own line, in this exact form:

```
<!-- commit: <one imperative-mood sentence, ≤80 chars, no trailing period> -->
```

That's it. No separate file, no extra tool call. The marker is part of the same `Write` / `Edit` you were doing anyway.

## How sync.sh uses it

After your turn ends, the `Stop` hook runs `sync.sh`, which:

1. Scans the staged memory files for a commit-message marker (HTML-comment form, syntax shown in **What to do** above)
2. Extracts the message inside it
3. Strips the marker from the file (so it doesn't leak into git history)

<!-- commit: reword marker-strip step in memory-commit skill -->
4. Re-stages the cleaned file
5. Commits with that message

Result: meaningful git log, clean memory files.

## Format rules

- Imperative mood ("add X", "note Y", "fix Z")
- ≥ 5 words and ≤ 80 chars per marker — enough to say *what* and *why/where* ("add ripgrep preference for code searches", not "fix search")
- No trailing period
- Describe the change, not the file path


## Multiple markers

sync.sh concatenates every non-fenced marker across staged files with ` + ` (final message clipped to 500 chars). One marker per logically distinct edit. Markers inside ``` code fences are preserved and never extracted.

## Style

Keep memory / skill content **compact** — every word lives in future agents' context windows. One line per fact / rationale / application step when possible. Skip examples unless they resolve genuine ambiguity. Verbose docs are a cost, not a kindness.

## Fallback

If you skip the marker, sync.sh writes a basename-based summary like `update CLAUDE.md`. Always prefer the marker.
