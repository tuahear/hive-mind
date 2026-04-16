# Adapters

hive-mind uses an **adapter pattern** to support multiple AI coding tools. Each adapter teaches hive-mind how to integrate with a specific tool — where its config lives, how its hooks work, what files to sync.

## Available adapters

| Adapter | Tool | Status |
|---|---|---|
| `claude-code` | [Claude Code](https://claude.com/claude-code) | Shipped |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | Planned (#11) |

## How it works

Core hive-mind logic (sync engine, merge drivers, marker extraction, project mirroring) is tool-agnostic. It lives in `core/` and takes all tool-specific paths from the loaded adapter at runtime (`$ADAPTER_DIR`, `$ADAPTER_LOG_PATH`, etc.). A few core scripts still carry a `~/.claude` fallback default so pre-refactor Claude installs keep working without re-running `setup.sh`; those fallbacks will be removed in the next major version once the migration window closes.

Each adapter lives in `adapters/<name>/` and answers questions like:
- Where is the config directory? (`~/.claude`, `~/.codex`, etc.)
- What events does the tool fire? (SessionStart, Stop, PostToolUse, etc.)
- How do hooks get installed? (JSON config, YAML, TOML, etc.)
- What files hold memory? (CLAUDE.md, AGENTS.md, etc.)
- What files must never be synced? (auth tokens, session data, etc.)

When you run `setup.sh`, it reads the `ADAPTER` env var (defaulting to `claude-code`), sources the adapter's `adapter.sh` through `core/adapter-loader.sh` (which validates the API version), and dispatches hook install + template seeding through the adapter interface. Multi-adapter detection (picking the right adapter when several tools are installed) will land with the second shipped adapter.

## For Claude Code users

Nothing changes. `setup.sh` defaults to the `claude-code` adapter (override with `ADAPTER=<name>` in the environment). Your hooks, memory, and skills work exactly as before.

The only visible change: hook commands in `settings.json` now reference `core/sync.sh` instead of `scripts/sync.sh`. The migration handles this automatically. Legacy `scripts/` paths still work via forwarding shims during the transition.

## Writing a new adapter

See the [Contributing adapters](./CONTRIBUTING-adapters.md) guide.
