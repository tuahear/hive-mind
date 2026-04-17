---
name: hive-mind
description: Load when editing a hive-mind-synced file: `~/.codex/AGENTS.override.md`, `~/.codex/hooks.json`, `~/.codex/config.toml`, `~/.agents/skills/*/*`. Triggers: remembering, saving a preference, updating a hook, or modifying a synced skill.
---

# Hive-mind commit marker

Embed, in the same edit, an HTML comment on its own line:

```
<!-- commit: <imperative summary of the change, at least 5 words, at most 80 chars, no trailing period> -->
```

## Notes

- Multiple markers across staged files are joined with ` + ` (final message clipped to 500 chars)
- Always embed a marker; without it the commit falls back to a basename summary
- Codex's current hook surface does not provide Claude-style edit events, so remember the marker yourself whenever you edit a hive-mind-managed file
