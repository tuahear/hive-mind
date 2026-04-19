// Adapter names flow into on-disk paths (adapters/<name>/...) and into
// the hub's .install-state/attached-adapters roster. Anything containing
// path separators, whitespace, or weird punctuation corrupts that state.
// Match kebab-case: leading letter, letters/digits/hyphens thereafter.
const ADAPTER_NAME_RE = /^[a-z][a-z0-9-]*[a-z0-9]$|^[a-z]$/;

export function validateAdapterName(name: string): string | null {
  if (!name) return "adapter name is required";
  if (!ADAPTER_NAME_RE.test(name)) {
    return `invalid adapter name '${name}'. Use kebab-case letters/digits (e.g. claude-code, codex).`;
  }
  return null;
}
