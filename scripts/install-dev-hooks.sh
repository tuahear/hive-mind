#!/bin/bash
# Install hive-mind developer git hooks into this clone's .git/hooks/.
#
# These hooks only matter to people EDITING the hive-mind repo (i.e. the
# maintainer). They're installed per-clone because git intentionally doesn't
# let tracked files execute at commit time for security reasons.
#
# Run once after cloning hive-mind on a new dev machine:
#   ~/.claude/hive-mind/scripts/install-dev-hooks.sh
#
# What the pre-commit hook does:
#   Strips `<!-- commit: ... -->` markers from staged templates/skills/**/*.md
#   before the commit lands. Prevents leaks from the hive-mind-dev mirror
#   workflow (agent cp's live skill file to template before sync.sh has
#   stripped its per-turn marker — without the hook, the marker would ship
#   to other users via the next setup.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"
HOOK="$HOOKS_DIR/pre-commit"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "error: $HOOKS_DIR not found. Run this inside a cloned hive-mind repo." >&2
    exit 1
fi

cat > "$HOOK" <<'HOOK_EOF'
#!/bin/bash
# hive-mind pre-commit: strip <!-- commit: ... --> markers from staged
# templates/skills/**/*.md. Fence-aware (preserves examples inside ```
# code fences). Mirrors scripts/sync.sh's extract logic.
set -e

touched=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    grep -q '<!--[[:space:]]*commit:' "$f" || continue

    tmp="$(mktemp)"
    awk '
      BEGIN { fence = 0 }
      /^[[:space:]]*```/ { fence = 1 - fence; print; next }
      fence == 1 { print; next }
      /^[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->[[:space:]]*$/ { next }
      { gsub(/[[:space:]]*<!--[[:space:]]*commit:[[:space:]]*[^>]+-->/, ""); print }
    ' "$f" > "$tmp"

    awk '{ lines[NR]=$0; last=NR }
         END {
           while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
           for (i=1; i<=last; i++) print lines[i]
         }' "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$tmp"

    if ! cmp -s "$f" "$tmp"; then
        mv "$tmp" "$f"
        git add "$f"
        echo "pre-commit: stripped commit marker(s) from $f" >&2
        touched=1
    else
        rm -f "$tmp"
    fi
done < <(git diff --cached --name-only --diff-filter=ACM | grep -E '^templates/skills/.*\.md$' || true)

exit 0
HOOK_EOF

chmod +x "$HOOK"
echo "installed pre-commit hook at $HOOK"
