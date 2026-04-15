---
name: hive-mind
description: Load when editing any hive-mind-synced file — `~/.claude/CLAUDE.md`, `~/.claude/projects/*/MEMORY.md`, `~/.claude/projects/*/memory/*`, or `~/.claude/skills/*/*`. Trigger phrases — remembering something, saving a user preference, updating a project memory or its index, adding feedback memory, creating or modifying a skill.
---

# Hive-mind commit marker

Embed — in the same edit — an HTML comment on its own line:

```
<!-- commit: <imperative summary, ≥5 words, ≤80 chars, no trailing period> -->
```

## Notes

- Multiple markers across staged files are joined with ` + ` (final message clipped to 500 chars)
- Always embed a marker; without it the commit falls back to a basename summary
