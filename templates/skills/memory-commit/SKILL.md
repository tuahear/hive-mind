---
name: memory-commit
description: Editing or writing Claude's memory files — `~/.claude/CLAUDE.md` or anything under `~/.claude/projects/*/memory/`. **Load this skill any time you are about to remember something, save a user preference, update a project memory, add feedback memory, or touch any file in those paths.** Embed a one-line commit-summary marker inside the edit and the hive-mind sync script will use it as the git commit message.
---

# Memory-commit convention

## When to use

Any time you write or edit:
- `~/.claude/CLAUDE.md`
- Any file under `~/.claude/projects/*/memory/`

## What to do

Embed a single HTML comment **inside the same edit**, on its own line, in this exact form:

```
<!-- commit: <one imperative-mood sentence, ≤80 chars, no trailing period> -->
```

That's it. No separate file, no extra tool call. The marker is part of the same `Write` / `Edit` you were doing anyway.

## How sync.sh uses it

After your turn ends, the `Stop` hook runs `sync.sh`, which:

1. Scans the staged memory files for the `<!-- commit: ... -->` marker
2. Extracts the message inside it
3. Strips the marker from the file (so it never enters git history)
4. Re-stages the cleaned file
5. Commits with that message

Result: meaningful git log, clean memory files.

## Examples

Adding a feedback memory:

```markdown
- prefer ripgrep over grep for new project searches
<!-- commit: add ripgrep preference for searches -->
```

Updating CLAUDE.md with a new shell preference:

```markdown
## Shell preferences

- Use `fd` instead of `find` when available — significantly faster.

<!-- commit: note fd as preferred find replacement -->
```

Wording fix in a project memory:

```markdown
demucs-gcs sits mid-pipeline as the source-separation stage.
<!-- commit: clarify demucs-gcs role as source-separation stage -->
```

## Format rules

- One marker per turn (only the first found is used)
- Imperative mood ("add X", "note Y", "fix Z")
- ≤80 characters
- No trailing period
- Describe *what* changed, not the file path

## Fallback

If you skip the marker, sync.sh writes a basename-based summary like `update CLAUDE.md`. Functional but loses context. Always prefer to include the marker.
