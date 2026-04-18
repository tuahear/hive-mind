---
name: hive-mind-claude
description: Load when editing a hive-mind-synced file — `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.claude/projects/*/MEMORY.md`, `~/.claude/projects/*/memory/*`, `~/.claude/skills/*/*`. Triggers — remembering, saving a preference, updating project memory, adding feedback, modifying a skill/hook/permission.
---

# Hive-mind commit marker

Embed — in the same edit — an HTML comment on its own line:

```
<!-- commit: <imperative summary of the change, ≥5 words, ≤80 chars, no trailing period> -->
```

## Notes

- Multiple markers across staged files are joined with ` + ` (final message clipped to 500 chars)
- Always embed a marker; without it the commit falls back to a basename summary
