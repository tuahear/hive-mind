import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { resolve } from "node:path";

// Well-known markers that a provider is installed on the machine. Used
// by init (and potentially future doctor output) to surface "you might
// want to attach this too" hints AFTER a successful install. Never
// triggers side effects — detection is informational, not
// configuration. Users still run `hivemind attach <name>` themselves.
//
// Extend this list as new adapters ship. Pick a marker that's strongly
// associated with the target tool and unlikely to be a false positive
// from an unrelated install.
type ProviderProbe = {
  adapter: string;
  marker: string;
  markerLabel: string;
};

function probes(): ProviderProbe[] {
  const home = homedir();
  return [
    { adapter: "claude-code", marker: resolve(home, ".claude"), markerLabel: "~/.claude/" },
    { adapter: "codex", marker: resolve(home, ".codex", "config.toml"), markerLabel: "~/.codex/config.toml" },
  ];
}

export type DetectedProvider = { adapter: string; markerLabel: string };

export function detectUnattachedProviders(attached: string[]): DetectedProvider[] {
  const attachedSet = new Set(attached);
  return probes()
    .filter((p) => existsSync(p.marker) && !attachedSet.has(p.adapter))
    .map(({ adapter, markerLabel }) => ({ adapter, markerLabel }));
}

export function printAttachSuggestions(suggestions: DetectedProvider[]): void {
  if (suggestions.length === 0) return;
  const pad = Math.max(...suggestions.map((s) => s.adapter.length));
  console.log("");
  console.log("Detected other attachable providers on this machine:");
  for (const s of suggestions) {
    console.log(`  - ${s.adapter.padEnd(pad)}  (found ${s.markerLabel})`);
  }
  console.log("Attach any of them with:");
  for (const s of suggestions) {
    console.log(`  hivemind attach ${s.adapter}`);
  }
}
