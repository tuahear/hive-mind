import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, dirname } from "node:path";

export function hubDir(): string {
  return process.env.HIVE_MIND_HUB_DIR || resolve(homedir(), ".hive-mind");
}

export function hubSrcDir(): string {
  return resolve(hubDir(), "hive-mind");
}

// Location of bundled assets inside the installed npm package. When the CLI
// is run from `dist/cli.js`, `__dirname` points at `<pkg>/dist`, so assets
// live at `<pkg>/assets`.
export function bundledAssetsDir(): string {
  return resolve(__dirname, "..", "assets");
}

export function attachedAdaptersFile(): string {
  return resolve(hubDir(), ".install-state", "attached-adapters");
}

export function readAttachedAdapters(): string[] {
  const f = attachedAdaptersFile();
  if (!existsSync(f)) return [];
  // Match core/hub/sync.sh's parser exactly so CLI output can't disagree
  // with what the sync engine iterates: split on '\n', keep lines
  // verbatim (no CR strip, no leading-whitespace trim), skip empty,
  // skip column-1 '#' comments.
  //
  // CRLF caveat: if the roster file is ever saved with Windows line
  // endings, core sees names with a trailing '\r' and fails to load
  // them. The CLI surfacing the same '\r'-suffixed names here is
  // intentional — it exposes the divergence to the user rather than
  // hiding it. A cross-cutting fix (make both parsers CR-tolerant)
  // belongs in a separate change that touches core too.
  return readFileSync(f, "utf8")
    .split("\n")
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

export function bundledVersion(): { cli: string; core: string } | null {
  const f = resolve(bundledAssetsDir(), "bundled.json");
  if (!existsSync(f)) return null;
  try {
    return JSON.parse(readFileSync(f, "utf8"));
  } catch {
    return null;
  }
}

export function coreVersion(): string | null {
  const v = resolve(hubSrcDir(), "VERSION");
  if (!existsSync(v)) return null;
  return readFileSync(v, "utf8").trim();
}

export { dirname };

// Core scripts (setup.sh, core/hub/sync.sh) gate on `-d .git`, so any
// "is this a real hub" check the CLI surfaces to the user must also
// require `.git` to be a directory. A worktree's `.git` file or a
// stale regular file would otherwise have the CLI report "installed"
// while core bails on sync.
export function isHubInstalled(dir: string): boolean {
  const g = resolve(dir, ".git");
  if (!existsSync(g)) return false;
  try {
    return statSync(g).isDirectory();
  } catch {
    return false;
  }
}
