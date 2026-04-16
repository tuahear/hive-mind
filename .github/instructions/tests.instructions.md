---
applyTo: "tests/**,adapters/*/tests/**"
---

# Review guidance for hive-mind test files

Test framework is [bats](https://github.com/bats-core/bats-core). Test layout:

- `tests/core/` — unused today; reserved for future core-only unit tests.
- `tests/adapter-conformance/` — parameterized over every registered adapter via `ADAPTER_UNDER_TEST`.
- `tests/integration/` — end-to-end scenarios parameterized over adapters.
- `tests/versioning/` — adapter API version, memory repo format version, install version compliance.
- `tests/fixtures/adapters/fake/` — fake adapter used by core tests.
- `adapters/<name>/tests/` — adapter-specific tests that don't generalize.

## Top principle: verify before asserting

Before flagging a test as broken or incorrect, read the test's setup/teardown and confirm the assertion actually fails under the described conditions. The general "verify before asserting" rule from the shell-scripts instructions applies here too.

## Don't re-raise resolved threads

Same rule as shell-scripts: if a prior review adjudicated a concern, don't re-raise without new evidence.

## Skip these kinds of comments

- **"Use `[[` instead of `[`"** or **"Use `$(cmd)` instead of backticks"** — stylistic; existing tests follow consistent conventions already.
- **"Quote this variable"** for tokens inside `[ "$x" = "$y" ]` where both sides are already-quoted — we quote everywhere, don't flag as new unless there's a real word-splitting risk.

## Raise these kinds of comments

- **Real portability bugs** — a GNU-only flag in the test that would break on macOS. Verify first (see the shell-scripts instructions for what's actually portable).
- **Tests that assert on implementation details** that shouldn't be pinned — e.g. a test that checks for a specific exit code sequence when the contract is "exit 0 always".
- **Missing regression coverage** for behaviors a PR intentionally adds — new logic without a matching test is worth flagging.
- **Version strings hardcoded to implausible values** (e.g. `0.0.0`) when setup.sh would actually pass `0.1.0` — tests should match the real call sites.

## Test-writing conventions

- **No hardcoded `~/.claude` or `CLAUDE.md`** in `tests/core/`, `tests/adapter-conformance/`, `tests/integration/`, or `tests/versioning/`. Only `adapters/claude-code/tests/` can reference those.
- **Use `$BATS_TMPDIR` or `mktemp -d`** for sandboxed filesystem state. Never touch the real `~/.claude`.
- **Set `HOME` in `setup()`** to isolate the test from the user's environment.
- **Adapter paths cannot contain newlines** (by contract) — newline-delimited `find | sort` is safe and portable; don't suggest `-z` / NUL-delimited forms unless genuinely needed.
