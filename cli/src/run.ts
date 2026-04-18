import { spawnSync, SpawnSyncOptions } from "node:child_process";

export type RunResult = { status: number; stdout: string; stderr: string };

export function run(cmd: string, args: string[], opts: SpawnSyncOptions = {}): RunResult {
  const res = spawnSync(cmd, args, {
    encoding: "utf8",
    stdio: opts.stdio ?? ["ignore", "pipe", "pipe"],
    ...opts,
  });
  return {
    status: typeof res.status === "number" ? res.status : -1,
    stdout: (res.stdout as string | undefined) ?? "",
    stderr: (res.stderr as string | undefined) ?? "",
  };
}

// Run bash with a script path + args. On Windows, this requires bash on PATH
// (Git Bash / MSYS / WSL). We don't try to emulate bash — setup.sh and core/
// are bash-only and that's a documented platform requirement.
export function runBash(scriptPath: string, args: string[] = [], env: NodeJS.ProcessEnv = {}): number {
  const res = spawnSync("bash", [scriptPath, ...args], {
    stdio: "inherit",
    env: { ...process.env, ...env },
  });
  if (res.error) {
    const e = res.error as NodeJS.ErrnoException;
    if (e.code === "ENOENT") {
      console.error(
        "error: bash not found on PATH. hive-mind's core is POSIX shell; install Git Bash (Windows), or ensure /bin/bash is available."
      );
      return 127;
    }
    throw res.error;
  }
  return typeof res.status === "number" ? res.status : 1;
}

export function which(cmd: string): boolean {
  const probe = process.platform === "win32" ? "where" : "which";
  const res = spawnSync(probe, [cmd], { stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
  return res.status === 0;
}
