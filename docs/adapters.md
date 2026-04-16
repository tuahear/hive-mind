# Adapters

hive-mind uses an **adapter pattern** to support multiple AI coding tools. Each adapter teaches hive-mind how to integrate with a specific tool — where its config lives, how its hooks work, what files to sync.

## Available adapters

| Adapter | Tool | Status |
|---|---|---|
| `claude-code` | [Claude Code](https://claude.com/claude-code) | Shipped |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | Planned (#11) |

## How it works

Core hive-mind logic (sync engine, merge drivers, marker extraction, project mirroring) is tool-agnostic. It lives in `core/` and never references any specific tool.

Each adapter lives in `adapters/<name>/` and answers questions like:
- Where is the config directory? (`~/.claude`, `~/.codex`, etc.)
- What events does the tool fire? (SessionStart, Stop, PostToolUse, etc.)
- How do hooks get installed? (JSON config, YAML, TOML, etc.)
- What files hold memory? (CLAUDE.md, AGENTS.md, etc.)
- What files must never be synced? (auth tokens, session data, etc.)

When you run `setup.sh`, it detects which tool is installed, loads the right adapter, and dispatches to core with that adapter's configuration.

## For Claude Code users

Nothing changes. After upgrading, `setup.sh` detects Claude Code and loads the `claude-code` adapter automatically. Your hooks, memory, and skills work exactly as before.

The only visible change: hook commands in `settings.json` now reference `core/sync.sh` instead of `scripts/sync.sh`. The migration handles this automatically. Legacy `scripts/` paths still work via forwarding shims during the transition.

## Writing a new adapter

See the [Contributing adapters](./CONTRIBUTING-adapters) guide.
