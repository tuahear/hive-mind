import { readFileSync, writeFileSync, chmodSync } from "node:fs";
import { resolve } from "node:path";

const target = resolve("dist/cli.js");
const shebang = "#!/usr/bin/env node\n";
const body = readFileSync(target, "utf8");
if (!body.startsWith("#!")) writeFileSync(target, shebang + body);
try { chmodSync(target, 0o755); } catch {}
