---
name: hive-mind
description: Editing or writing any of Claude's hive-mind-synced files — `~/.claude/CLAUDE.md`, anything under `~/.claude/projects/*/memory/`, `~/.claude/projects/*/MEMORY.md` (index), or anything under `~/.claude/skills/*/`. **Load this skill any time you are about to remember something, save a user preference, update a project memory, update a project MEMORY index, add feedback memory, create or modify a skill, or touch any file in those paths.** Embed a one-line commit-summary marker inside the edit; the hive-mind sync script extracts it, strips it from the file, and uses it as the git commit message.
---

# Hive-mind commit marker

Any edit under `~/.claude/CLAUDE.md`, `~/.claude/projects/*/MEMORY.md`, `~/.claude/projects/*/memory/*`, or `~/.claude/skills/*/*` must embed — in the same edit — an HTML comment on its own line:

```
<!-- commit: <imperative summary, ≥5 words, ≤80 chars, no trailing period> -->
```

The hive-mind sync script extracts the text, strips the marker from the file, and uses it as the git commit message.

## Notes

- Multiple markers across staged files are joined with ` + ` (final message clipped to 500 chars)
- Markers inside ``` ``` ``` code fences are preserved and never extracted (safe to include as documentation examples)
- Keep memory/skill content compact — every word enters future agents' context windows
- No marker → sync.sh falls back to `update <basenames>`, which is legible but uninformative; always prefer the marker
