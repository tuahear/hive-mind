import { Command } from "commander";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { bundledAssetsDir, bundledVersion, coreVersion, hubDir, readAttachedAdapters } from "./paths.js";
import { initCmd } from "./commands/init.js";
import { attachCmd } from "./commands/attach.js";
import { detachCmd } from "./commands/detach.js";
import { statusCmd, syncCmd, pullCmd } from "./commands/status.js";
import { doctorCmd } from "./commands/doctor.js";

const pkg = JSON.parse(readFileSync(resolve(__dirname, "..", "package.json"), "utf8")) as { version: string };

async function main(): Promise<number> {
  const program = new Command();
  program
    .name("hivemind")
    .description("hive-mind CLI — install, attach, and sync an AI-agent memory hub")
    .version(pkg.version, "-v, --version", "show CLI version");

  program
    .command("init")
    .description("install the hub and attach an initial adapter (replaces `bash setup.sh`)")
    .option("-a, --adapter <name>", "adapter to attach (claude-code, codex, ...)", "claude-code")
    .option("-m, --memory-repo <url>", "SSH URL of your private memory repo")
    .option("-y, --yes", "non-interactive (requires --memory-repo or existing origin)")
    .action(async (opts) => process.exit(await initCmd(opts)));

  program
    .command("attach <adapter>")
    .description("attach an additional adapter to the existing hub")
    .action((adapter: string) => process.exit(attachCmd(adapter)));

  program
    .command("detach <adapter>")
    .description("uninstall an adapter's hooks; hub content is preserved")
    .action((adapter: string) => process.exit(detachCmd(adapter)));

  program
    .command("status")
    .description("show hub state: attached adapters, origin, unpushed commits")
    .option("--json", "machine-readable output")
    .action((opts) => process.exit(statusCmd(!!opts.json)));

  program
    .command("sync")
    .description("run the hub's sync flow (harvest -> pull -> push -> fan-out)")
    .option("--force-push", "pass --force-push through to the sync script")
    .action((opts) => process.exit(syncCmd(!!opts.forcePush)));

  program
    .command("pull")
    .description("git pull --rebase --autostash on the hub")
    .action(() => process.exit(pullCmd()));

  program
    .command("doctor")
    .description("run diagnostic checks against the hub and attached adapters")
    .option("--json", "machine-readable output")
    .action((opts) => process.exit(doctorCmd(!!opts.json)));

  program
    .command("version")
    .description("print CLI + bundled + installed core versions (human or --json)")
    .option("--json", "machine-readable output")
    .action((opts) => {
      const bundled = bundledVersion();
      const payload = {
        cli: pkg.version,
        bundledCore: bundled?.core ?? null,
        installedCore: coreVersion(),
        hub: hubDir(),
        attached: readAttachedAdapters(),
      };
      if (opts.json) {
        console.log(JSON.stringify(payload, null, 2));
      } else {
        console.log(`hivemind ${payload.cli}`);
        console.log(`  bundled core:   ${payload.bundledCore ?? "(missing)"}`);
        console.log(`  installed core: ${payload.installedCore ?? "(not installed)"}`);
        console.log(`  hub:            ${payload.hub}`);
        console.log(`  attached:       ${payload.attached.length ? payload.attached.join(", ") : "(none)"}`);
      }
      process.exit(0);
    });

  program
    .command("assets-path")
    .description("print the path to the CLI's bundled assets (debug helper)")
    .action(() => {
      console.log(bundledAssetsDir());
      process.exit(0);
    });

  await program.parseAsync(process.argv);
  return 0;
}

main().catch((err: unknown) => {
  const msg = err instanceof Error ? err.message : String(err);
  console.error(`error: ${msg}`);
  process.exit(1);
});
