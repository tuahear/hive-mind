import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { attachedAdaptersFile, hubDir, hubSrcDir, readAttachedAdapters } from "../paths.js";
import { run } from "../run.js";

// detach is a small shell wrapper: source the adapter contract, invoke
// adapter_uninstall_hooks, then strike the adapter's row from the
// attached-adapters file. Intentionally NOT in setup.sh — setup.sh is
// an attach-or-upgrade script; detach is a distinct lifecycle op.
const DETACH_SH = [
  "set -euo pipefail",
  ': "${HIVE_MIND_HUB_DIR:?}"',
  ': "${ADAPTER:?}"',
  'SRC="$HIVE_MIND_HUB_DIR/hive-mind"',
  'ADAPTER_ROOT="$SRC/adapters/$ADAPTER"',
  "[ -d \"$ADAPTER_ROOT\" ] || { echo \"error: unknown adapter '$ADAPTER'\" >&2; exit 1; }",
  "export ADAPTER_ROOT HIVE_MIND_HUB_DIR",
  '. "$SRC/core/adapter-loader.sh"',
  'load_adapter "$ADAPTER"',
  "if declare -F adapter_uninstall_hooks >/dev/null; then",
  "  adapter_uninstall_hooks",
  "else",
  "  echo \"warning: adapter '$ADAPTER' defines no adapter_uninstall_hooks; skipping\" >&2",
  "fi",
].join("\n");

export function detachCmd(adapter: string): number {
  const src = hubSrcDir();
  if (!existsSync(resolve(src, "core", "adapter-loader.sh"))) {
    console.error("error: hub not initialized. Run `hivemind init` first.");
    return 1;
  }

  const attached = readAttachedAdapters();
  if (!attached.includes(adapter)) {
    console.error(`error: adapter '${adapter}' is not attached. Attached: ${attached.join(", ") || "(none)"}`);
    return 1;
  }

  const res = run("bash", ["-c", DETACH_SH], {
    stdio: "inherit",
    env: { ...process.env, HIVE_MIND_HUB_DIR: hubDir(), ADAPTER: adapter },
  });
  if (res.status !== 0) return res.status;

  const remaining = attached.filter((a) => a !== adapter);
  const f = attachedAdaptersFile();
  try {
    mkdirSync(dirname(f), { recursive: true });
    writeFileSync(f, remaining.length ? remaining.join("\n") + "\n" : "");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`error: detach succeeded but failed to update ${f}: ${msg}`);
    return 1;
  }
  console.log(`[hivemind] detached ${adapter} (hub content preserved)`);
  return 0;
}
