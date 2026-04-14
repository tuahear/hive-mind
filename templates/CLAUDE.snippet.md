## Memory-commit convention

When you write or edit `~/.claude/CLAUDE.md` or any file under `~/.claude/projects/*/memory/`, also write one imperative-mood sentence (≤80 chars, no trailing period) to `~/.claude/.commit-msg` describing *what* changed. sync.sh uses it as the commit message and deletes the file.
