# Adapters

hive-mind uses a **hub-and-adapter** topology.

- One **hub** per machine: `~/.hive-mind/`. Single git repo, single remote, provider-agnostic schema.
- One **adapter** per AI tool: a bidirectional mapper between the hub's canonical layout and the tool's native config dir. Adapters don't own a git repo — they attach to the hub.

That split lets you run multiple AI coding tools on the same machine against the same memory without clobbering each other, and lets two machines share that memory through a single remote.

## Hub layout

```
~/.hive-mind/
├── .git/                              ← single git repo; remote = your memory repo
├── content.md                         ← canonical global content (maps to CLAUDE.md, AGENTS.md, etc.)
├── projects/<project-id>/             ← project-id = normalized git remote
│   ├── content.md                     ← per-project content (maps to MEMORY.md, etc.)
│   └── memory/**                      ← per-project subfiles (subdirs preserved via project rules)
├── skills/<name>/content.md           ← skill content (maps to SKILL.md on fan-out)
├── config/
│   ├── hooks/<event>/<id>.json        ← tool-agnostic hook entries
│   ├── permissions/{allow,deny,ask}.txt
│   └── env.sh                         (reserved for v0.3.1+)
├── bin/sync                           ← hook entry point (symlink)
├── hive-mind/                         ← cloned hive-mind source (gitignored)
├── .install-state/attached-adapters   ← one adapter name per line (gitignored)
└── .hive-mind-state/                  ← sync lock + last-push timestamp (gitignored)
```

Lowercase filenames signal "hive-mind canonical"; each adapter maps them to tool-native names (`CLAUDE.md`, `AGENTS.md`, `QWEN.md`, `KIMI.md`) during fan-out.

## Available adapters

| Adapter | Tool | Status |
|---|---|---|
| [`claude-code`](/adapters/claude-code) | [Claude Code](https://claude.com/claude-code) | Shipped |
| `codex` | [OpenAI Codex CLI](https://github.com/openai/codex) | Planned ([#11](https://github.com/tuahear/hive-mind/issues/11)) |
| `qwen` | [Qwen CLI](https://github.com/QwenLM/qwen-code) | Planned ([#19](https://github.com/tuahear/hive-mind/issues/19)) |
| `kimi` | [Kimi CLI](https://github.com/MoonshotAI/kimi-cli) | Planned ([#23](https://github.com/tuahear/hive-mind/issues/23)) |

## How a sync cycle works

Each attached tool's Stop hook fires `~/.hive-mind/bin/sync`, which runs a single lock-guarded flow:

1. **Harvest** — for every attached adapter, read its tool dir and apply `ADAPTER_HUB_MAP` + `ADAPTER_PROJECT_CONTENT_RULES` in the tool→hub direction.
2. **Pull-rebase** — fetch and rebase on top of other machines' commits.
3. **Push** — publish this machine's commits, rate-limited to 10 s by default.
4. **Fan-out** — for every attached adapter, apply the same maps in the hub→tool direction; deep-merge into JSON configs so tool-specific fields the hub doesn't know about survive.

A **machine-local filter** skips harvesting any hook whose command references `/Applications/`, `/opt/homebrew/`, `/tmp/`, Windows drive letters, and similar machine-specific paths. These stay tool-local and are preserved through fan-out too.

## Attaching a second adapter

Once another adapter ships (e.g. `codex`), attach it to the same hub with:

```bash
ADAPTER=codex bash setup.sh
```

This does *not* touch the first adapter's install. Both adapters then harvest and fan-out through the same `~/.hive-mind/` — memory edits in one tool appear in the other on the next sync cycle.

## Writing a new adapter

See the [Contributing adapters](/CONTRIBUTING-adapters) guide. The short version: declare two mapping strings (`ADAPTER_HUB_MAP`, `ADAPTER_PROJECT_CONTENT_RULES`) plus six contract functions, drop an adapter dir under `adapters/<name>/`, and `ADAPTER=<name> bash setup.sh` does the rest.
