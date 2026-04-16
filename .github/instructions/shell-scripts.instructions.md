---
applyTo: "core/*.sh,adapters/**/*.sh,setup.sh,scripts/*.sh"
---

# Review guidance for hive-mind shell scripts

This project is **pure bash + standard POSIX userland** (awk/sed/grep/tr/cut/sort/mktemp/jq). Hook-invoked scripts (`core/sync.sh`, `core/check-dupes.sh`, `core/mirror-projects.sh`, `core/marker-nudge.sh`) must never block an agent session — every failure path logs and exits 0. `setup.sh` is the exception: it's the installer, uses strict mode, and exits non-zero on failures. Comments below are specifically for Copilot code review; they distill patterns that wasted review rounds on this codebase.

## Top principle: verify before asserting

Before raising any claim about file content or behavior, read the file. The single largest category of wasted review rounds on this repo has been hallucinated claims (non-existent syntax errors, fabricated portability issues, imagined missing files). If a claim can't be supported from the diff + surrounding context, do not raise it.

## Don't re-raise resolved threads

If a prior review round already adjudicated a concern (visible in the PR's resolved threads), do not re-raise it without new evidence. When a contributor replies with an intentional design choice and rationale, treat the thread as settled.

## Skip these kinds of comments

They're usually wrong or noise in this repo:

- **"`<tool>` isn't on macOS / BSD / busybox"** — verify per-flag availability with `man <tool>` on macOS (or against the BSD manpages) before asserting non-portability. Real platform divergences — e.g. `stat -c` (GNU) vs `stat -f` (BSD), GNU-only long options on `sed` / `awk` — are worth flagging. Don't assume non-portability of common flags without checking; many widely-assumed-GNU flags are in fact available on current macOS.
- **"This comment claims pure POSIX but the code uses bash `[[`"** — we use bash features freely. The contract is "no python/node/go"; bash + standard userland is the floor, not POSIX sh.
- **"Missing `set -e` / `pipefail`"** on hook-reached scripts — `core/sync.sh`, `core/check-dupes.sh`, `core/mirror-projects.sh`, `core/marker-nudge.sh` run with `set +e` by design. Flagging missing strict-mode on these is a false positive — move on.
- **Stylistic comment drift** — whether a header comment says "core/X.sh" vs "scripts/X.sh" is not load-bearing for a reviewer to raise unless the documented command is wrong and users will copy-paste it.

## Raise these kinds of comments — they're high-value

- **Real bugs**: conditions that never fire, commits that never get pushed, state files written inside git checkouts that `git pull` clobbers, `@{u}` used without falling back for no-upstream case.
- **Missing validation at system boundaries**: numeric inputs from disk/env that trip arithmetic errors on bad data, required adapter variables silently accepted as empty strings, enum fields accepting arbitrary values.
- **Contract violations**: a field documented as required-and-enforced but the loader doesn't check it; a function called in core that's not validated to exist on the adapter.
- **Concurrency hazards**: two hook processes racing on `git index.lock`, sentinel writes with no stderr redirect leaking into the hook transcript.
- **Silent data loss**: parser exits 0 but drops unparsed lines; merge driver claims success but corrupts output.

## Anti-patterns specific to this repo

- **Don't suggest splitting "update comment" + "update code" into separate PRs** — one commit is fine here.
- **Don't suggest extracting helper functions** for 2-line snippets. Core stays flat and grep-able on purpose.
- **Don't suggest feature flags / partial rollout knobs** in core. Experiments live in an adapter.
- **Don't suggest Python/Node for "cleaner" parsing.** Bash is a constraint, not a deficiency.
- **Don't suggest telemetry / crash reporting / analytics** — stated non-goal, including sneakier framings like "version ping," "metrics ingestion," "tracking ID header."
- **Don't flag `ADAPTER_DIR` fallback to `~/.claude`** in core scripts — that's deliberate backward compat for pre-refactor hook command strings.
- **Don't suggest parameterizing single-origin hardcoded values** (e.g. `base` paths, repo URLs) via env vars. Single-origin OSS projects don't benefit from runtime parameterization; a fork changes the whole config file anyway.

## Hooks must never block

Any script in `core/` or `scripts/` reached through the hook system (sync, check-dupes, mirror-projects, marker-nudge) must:

1. Run with `set +e`.
2. Redirect stderr of every command to `$LOG` or `/dev/null`.
3. Exit 0 on every path.
4. Not emit any stdout except the specific JSON payload for hooks that use `hookSpecificOutput`.

If you see a raw command in a hook-reached script without a redirect, that's worth a comment. If you see `exit <non-zero>` in such a script, that's worth a comment. Otherwise, assume `set +e` + trailing `exit 0` does the right thing.

## When in doubt about a file's purpose

- `core/*` — tool-agnostic logic. Hardcoding `~/.claude` or `CLAUDE.md` here is always wrong.
- `adapters/<name>/*` — tool-specific. Hardcoding the tool's own paths here is expected.
- `scripts/*` — deprecated forwarding shims. Don't suggest feature additions; they'll be deleted next major.
- `tests/fixtures/adapters/fake/*` — test-only adapter. Don't suggest hardening its healthcheck or adding CI for it beyond what the conformance suite exercises.

## Repo conventions

- Kebab-case for directory/adapter names, snake_case for shell functions, UPPER_SNAKE_CASE for exported vars.
- All adapter contract symbols start with `ADAPTER_` (vars) or `adapter_` (functions).
- Commit marker convention: `<!-- commit: <imperative, ≥5 words, ≤80 chars, no period> -->` — markers on their own line are extracted by `core/marker-extract.sh`; markers inside ``` code fences are preserved.
