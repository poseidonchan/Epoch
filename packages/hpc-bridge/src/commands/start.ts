import process from "node:process";

import { loadConfig } from "../config.js";
import { configDir } from "../config.js";
import { isProcessRunning, readBridgeDaemonInfo, startBridgeDaemon, stopBridgeDaemon } from "../daemon.js";
import { BridgeService } from "../service.js";

function hasFlag(argv: string[], flag: string) {
  return argv.includes(flag);
}

export async function startCommand(argv: string[]) {
  const cfg = await loadConfig();
  if (!cfg) {
    throw new Error("Config missing. Run: epoch-bridge config");
  }

  const foreground = hasFlag(argv, "--foreground") || hasFlag(argv, "-f");
  if (!foreground) {
    const stateDir = configDir();
    const existing = await readBridgeDaemonInfo(stateDir);
    if (existing && Number.isFinite(existing.pid) && existing.pid > 1 && isProcessRunning(existing.pid)) {
      console.log(`Epoch Bridge already running (pid ${existing.pid}).`);
      return;
    }
    await stopBridgeDaemon(stateDir).catch(() => {});

    const info = await startBridgeDaemon({
      stateDir,
      cliPath: process.argv[1] ?? "",
      nodePath: process.execPath,
      env: process.env,
      cwd: process.cwd(),
    });
    console.log(`Epoch Bridge started (pid ${info.pid}). Logs: ${info.logPath}`);
    return;
  }

  const service = new BridgeService(cfg);
  await service.start();
}
