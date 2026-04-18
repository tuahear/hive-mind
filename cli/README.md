# hive-mind CLI (prototype)

`hivemind` is the user-facing CLI for the [hive-mind](https://github.com/tuahear/hive-mind) memory hub. It wraps the bash core so installing and managing a hub does not require cloning the whole `hive-mind` repo.

**Status:** prototype for issue [#13](https://github.com/tuahear/hive-mind/issues/13). Surface is small on purpose — enough to validate the packaging story end-to-end.

## What it does today

```
hivemind init                  # install hub, attach first adapter (default: claude-code)
hivemind attach <adapter>      # attach additional adapter (codex, ...)
hivemind detach <adapter>      # remove an adapter's hooks (preserves hub content)
hivemind status [--json]       # attached adapters, origin, unpushed commits
hivemind sync [--force-push]   # run the hub's sync flow
hivemind pull                  # git pull --rebase --autostash
hivemind restage [--force-stage]  # refresh staged core from the CLI's bundled assets (upgrade step)
hivemind doctor [--json]       # diagnostic checks
hivemind version [--json]      # CLI + bundled core + installed core
hivemind assets-path           # print the directory holding the CLI's bundled assets
```

## Why this fixes the install pain

The legacy path (`bash setup.sh`) requires a full `git clone` of the `hive-mind` repo into `~/.hive-mind/hive-mind/`. That's a hard stop on machines without GitHub SSH, adds a ~MB transfer, and means every user has a mutable working copy of the source tree.

This CLI ships the bash `core/`, `adapters/`, and `cmd/` trees **inside the npm tarball** (~70 KB gzipped). `hivemind init` copies those bundled assets into `~/.hive-mind/hive-mind/` and runs `setup.sh` with `HIVE_MIND_SKIP_CLONE=1`, which short-circuits the clone/pull branch.

Upgrade flow: `npm install -g hive-mind@latest` refreshes the CLI's *bundled* assets, then `hivemind restage` copies them over `~/.hive-mind/hive-mind/`. Hooks and attached adapters stay put — re-run `hivemind init` / `hivemind attach` only if hook wiring changed. No user-side `git clone` or `git pull` anywhere in the loop.

## Layout

```
cli/
  src/              TypeScript source
    cli.ts          commander entrypoint
    commands/       one file per subcommand
    paths.ts        hub paths + bundled-asset resolution
    run.ts          subprocess helpers
  scripts/
    bundle-assets.mjs  copies ../core ../adapters ../cmd ../setup.sh ../VERSION ../go.mod into assets/
    shebang.mjs        prepends the node shebang to dist/cli.js
  dist/             tsc output (gitignored)
  assets/           bundled bash core (gitignored; populated by prepack)
```

## Build + pack locally

```bash
cd cli/
npm install
npm run build          # tsc + shebang + bundle-assets
npm pack               # -> hive-mind-<version>.tgz  (~70 KB)
npm install -g ./hive-mind-*.tgz
hivemind --version
```

## Not yet implemented (deferred)

Compared to the [#13](https://github.com/tuahear/hive-mind/issues/13) spec, this prototype omits:

- `memory list|show|edit|search`, `skills list|install|remove`, `config get|set`, `log`, `debug-bundle`, `upgrade`, `downgrade`
- Bun `--compile` single-file binaries (brew / scoop / curl-pipe-sh channels)
- Release workflow + tap + bucket + `hivemind.sh/install`
- Tests (unit / bridge / e2e / channel / version / a11y)
- `--no-color` / `NO_COLOR` / a11y surface
- Marker-aware log pretty-printer

These are the right next slices, but none of them are needed to prove the core packaging story works.
