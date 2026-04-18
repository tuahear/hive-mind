---
name: hive-mind-claude
description: Load when editing a hive-mind-synced file — `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.claude/projects/*/MEMORY.md`, `~/.claude/projects/*/memory/*`, `~/.claude/skills/*/*`. Triggers — remembering, saving a preference, updating project memory, adding feedback, modifying a skill/hook/permission. Every edit requires an embedded commit marker; without it the sync commit falls back to a basename summary.
---

# Hive-mind commit marker

Embed — in the same edit — an HTML comment on its own line:

```
<!-- commit: <imperative summary of the change, ≥5 words, ≤80 chars, no trailing period> -->
```

## Notes

- Multiple markers across staged files are joined with ` + ` (final message clipped to 500 chars)
- Always embed a marker; without it the commit falls back to a basename summary

## Section markers in CLAUDE.md

CLAUDE.md may contain paired `<!-- hive-mind:section=N START -->` ... `<!-- hive-mind:section=N END -->` blocks. These are sync-tier boundaries — cross-adapter shared content lives outside any block (section 0, the default); each tagged block belongs to a specific tool (e.g. section 1 is Codex's override layer). Add new shared notes outside any block so they fan out to every adapter. Edit inside a block only when you intend that tool-specific tier. Don't hand-remove the markers — harvest routes content by them; losing them reclassifies the block as shared (no data loss, just a privacy downgrade).
