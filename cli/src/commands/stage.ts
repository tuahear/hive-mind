// Shared staging helper used by init and restage. Copies the CLI's
// bundled assets over the hub source tree, but first captures the
// currently-installed VERSION string so setup.sh's adapter_migrate
// hook can still see the pre-upgrade version (it defaults to reading
// $HIVE_MIND_SRC/VERSION, which we're about to overwrite).

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";

export type StageResult =
  | { ok: true; prevVersion: string }
  | { ok: false; code: number };

export const STAGE_REQUIRED = ["core", "adapters", "cmd", "setup.sh", "VERSION", "go.mod"];

export function capturePrevVersion(src: string, hubStateDir?: string): string {
  // Prefer an earlier-persisted marker (written by `hivemind restage`) —
  // without it, a restage-then-init sequence would read the already-
  // overwritten VERSION and lose the real previous version.
  if (hubStateDir) {
    const marker = resolve(hubStateDir, "prev-version");
    if (existsSync(marker)) {
      try {
        const raw = readFileSync(marker, "utf8").trim();
        if (raw.length) return raw;
      } catch {
        // fall through to file probe
      }
    }
  }
  const v = resolve(src, "VERSION");
  if (!existsSync(v)) return "0.1.0"; // matches setup.sh's sentinel
  try {
    const raw = readFileSync(v, "utf8").trim();
    return raw.length ? raw : "0.1.0";
  } catch {
    return "0.1.0";
  }
}

export function stageAssets(src: string, assets: string, hubStateDir?: string): StageResult {
  if (!existsSync(resolve(assets, "setup.sh"))) {
    console.error(`error: bundled assets missing at ${assets}. CLI build is broken.`);
    return { ok: false, code: 1 };
  }
  const prevVersion = capturePrevVersion(src, hubStateDir);

  mkdirSync(src, { recursive: true });
  for (const item of STAGE_REQUIRED) {
    const s = resolve(assets, item);
    if (!existsSync(s)) {
      console.error(`error: bundled asset '${item}' missing from ${assets}. CLI build is incomplete.`);
      return { ok: false, code: 1 };
    }
    const dst = resolve(src, item);
    rmSync(dst, { recursive: true, force: true });
    cpSync(s, dst, { recursive: true });
  }
  return { ok: true, prevVersion };
}
