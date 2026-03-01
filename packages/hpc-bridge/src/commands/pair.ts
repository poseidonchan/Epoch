import process from "node:process";

import { saveConfig } from "../config.js";
import { configCommand } from "./config.js";

export async function pairCommand(argv: string[]) {
  const hubUrl = flag(argv, "--hub");
  const token = flag(argv, "--token");
  const workspaceRoot = flag(argv, "--workspace-root");

  if (!hubUrl || !token || !workspaceRoot) {
    if (process.stdin.isTTY && process.stdout.isTTY) {
      console.log("`pair` is a compatibility alias for `config`.");
      await configCommand(argv, { mode: "config" });
      return;
    }
    console.error("Usage: labos-hpc-bridge pair --hub <wss://...> --token <token> --workspace-root <absolute-path>");
    console.error("Hint: run `labos-hpc-bridge config` for interactive setup.");
    process.exitCode = 1;
    return;
  }

  const cfg = await saveConfig({
    hubUrl,
    token,
    workspaceRoot,
    defaults: {
      partition: flag(argv, "--partition") ?? undefined,
      account: flag(argv, "--account") ?? undefined,
      qos: flag(argv, "--qos") ?? undefined,
      timeLimitMinutes: numFlag(argv, "--time-mins") ?? undefined,
      cpus: numFlag(argv, "--cpus") ?? undefined,
      memMB: numFlag(argv, "--mem-mb") ?? undefined,
      gpus: numFlag(argv, "--gpus") ?? undefined,
    },
  });

  console.log("Saved config:");
  console.log(`- hubUrl: ${cfg.hubUrl}`);
  console.log(`- nodeId: ${cfg.nodeId}`);
  console.log(`- workspaceRoot: ${cfg.workspaceRoot}`);
  console.log("Hint: run `labos-hpc-bridge start` to connect this bridge.");
}

function flag(argv: string[], name: string) {
  const idx = argv.indexOf(name);
  if (idx === -1) return null;
  return argv[idx + 1] ?? null;
}

function numFlag(argv: string[], name: string) {
  const v = flag(argv, name);
  if (v == null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
