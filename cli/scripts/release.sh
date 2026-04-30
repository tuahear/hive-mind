#!/bin/sh
# Prep a hivemind CLI release: bump version, rebuild from a clean tree,
# enforce prebuilt hivemind-hook binaries, smoke-test, pack the tarball.
# Does NOT create the GitHub Release — that step is manual so you can
# review the draft notes file and edit before `gh release create`.
#
# Usage: cli/scripts/release.sh <new-version>
# Example: cli/scripts/release.sh 0.3.0-prototype.2
#
# POSIX sh on purpose (see feedback_cross_platform_scripts memory) —
# no bash arrays, no [[ ]], no process substitution.

set -eu

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <new-version>   (e.g. 0.3.0-prototype.2)" >&2
    exit 2
fi

# Resolve paths independent of the caller's cwd so the script works from
# anywhere (repo root, cli/, or /tmp).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CLI_DIR/.." && pwd)"

cd "$CLI_DIR"

# --- preflight ---
need() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: required tool not on PATH: $1" >&2
        exit 1
    fi
}
need node
need npm
need go   # release requires cross-compiled prebuilts; enforced below too

if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --quiet --cached; then
    echo "warning: repo has uncommitted changes. Release artifacts will include them." >&2
    printf "Continue anyway? [y/N] "
    read -r ans
    case "$ans" in
        y|Y) ;;
        *) echo "aborted."; exit 1 ;;
    esac
fi

# --- bump version ---
# Bump cli/package.json AND repo-root VERSION in lockstep. The latter is
# bundled into the tarball by bundle-assets.mjs, copied to
# ~/.hive-mind/hive-mind/VERSION by `hivemind init/restage`, and read by
# setup.sh as PREV_HIVE_MIND_VERSION for adapter_migrate. Skipping the
# repo-root bump leaves every install reporting the same stale core
# version forever and silently breaks any future version-gated migration.
echo "--> bumping cli/package.json to $VERSION"
node -e '
  const fs = require("node:fs");
  const p = JSON.parse(fs.readFileSync("package.json", "utf8"));
  p.version = process.argv[1];
  fs.writeFileSync("package.json", JSON.stringify(p, null, 2) + "\n");
' "$VERSION"
echo "--> bumping $REPO_ROOT/VERSION to $VERSION"
printf '%s\n' "$VERSION" > "$REPO_ROOT/VERSION"

# --- clean build ---
echo "--> cleaning dist/ and assets/"
rm -rf dist assets
# npm install is idempotent and cheap; skip if node_modules exists to keep reruns fast.
[ -d node_modules ] || npm install --no-audit --no-fund

echo "--> building with HIVE_MIND_REQUIRE_PREBUILT=1 (hard-fail if Go missing)"
HIVE_MIND_REQUIRE_PREBUILT=1 npm run build

# --- verify prebuilts present ---
missing=""
for target in \
    hivemind-hook-darwin-arm64 \
    hivemind-hook-darwin-amd64 \
    hivemind-hook-linux-amd64 \
    hivemind-hook-linux-arm64 \
    hivemind-hook-windows-amd64.exe
do
    [ -f "assets/prebuilt/$target" ] || missing="$missing $target"
done
if [ -n "$missing" ]; then
    echo "error: build finished but these prebuilts are missing:$missing" >&2
    exit 1
fi

# --- smoke ---
echo "--> running smoke tests"
node scripts/smoke.mjs
rm -rf .smoke-*

# --- pack ---
echo "--> packing tarball"
rm -f hive-mind-*.tgz
npm pack
TARBALL="$(ls hive-mind-*.tgz)"
SIZE_KB="$(node -e 'console.log((require("node:fs").statSync(process.argv[1]).size / 1024).toFixed(1))' "$TARBALL")"
echo "--> packed: $TARBALL ($SIZE_KB KB)"

# --- draft release notes ---
DRAFT_DIR="$CLI_DIR/.release-notes"
mkdir -p "$DRAFT_DIR"
DRAFT="$DRAFT_DIR/cli-v${VERSION}.md"
if [ -f "$DRAFT" ]; then
    echo "--> release-notes draft already exists at: $DRAFT"
    echo "    (not overwriting; edit in place or delete + rerun)"
else
    cat > "$DRAFT" <<EOF
# hivemind CLI $VERSION

## Highlights

<!-- TODO: one-to-three sentence summary of what changed since the last release -->

## Install on macOS / Linux

\`\`\`
gh release download cli-v${VERSION} --repo tuahear/hive-mind --pattern 'hive-mind-*.tgz' --output /tmp/hive-mind.tgz
npm install -g /tmp/hive-mind.tgz
hivemind init --memory-repo git@github.com:YOU/your-memory.git
\`\`\`

## What's in the tarball

- Bundled bash \`core/\` + \`adapters/\` + \`setup.sh\`
- Prebuilt \`hivemind-hook\` binaries: darwin arm64/amd64, linux amd64/arm64, windows amd64
- CLI entrypoint: \`hivemind\`

## Prereqs

- Node 18+
- \`git\`

Go is NOT required at user install time (prebuilts are bundled). Go is only needed when building the CLI from source.

## Notes

<!-- TODO: user-facing changes, breaking changes, known issues, anything noteworthy -->

## Details

- PR: https://github.com/tuahear/hive-mind/pull/28
- Tarball size: $SIZE_KB KB
- Built from: \`$(git -C "$REPO_ROOT" rev-parse --short HEAD)\` on $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    echo "--> wrote draft release notes to: $DRAFT"
fi

# --- hand-off ---
cat <<EOF

================================================================
Release artifacts ready. Next steps (you drive):

  1. Edit the draft release notes:
       \$EDITOR '$DRAFT'

  2. Commit the version bump (and CHANGELOG entry if you add one):
       git -C '$REPO_ROOT' add cli/package.json VERSION CHANGELOG.md
       git -C '$REPO_ROOT' commit -m "cli: release v$VERSION"
       git -C '$REPO_ROOT' push

  3. Create the GitHub Release with the tarball attached:
       gh release create cli-v$VERSION \\
         --repo tuahear/hive-mind \\
         --prerelease \\
         --title "hivemind CLI v$VERSION" \\
         --notes-file '$DRAFT' \\
         '$CLI_DIR/$TARBALL'

     (drop --prerelease for stable releases)

  4. Clean up local artifacts once the release is live:
       rm '$CLI_DIR/$TARBALL'
       # .release-notes/ stays (gitignored history of past release bodies)
================================================================
EOF
