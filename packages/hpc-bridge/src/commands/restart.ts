import process from "node:process";

import { configDir, loadConfig } from "../config.js";
import { startBridgeDaemon, stopBridgeDaemon } from "../daemon.js";

export async function restartCommand(_argv: string[]) {
  const cfg = await loadConfig();
  if (!cfg) {
    throw new Error("Config missing. Run: epoch-bridge config");
  }

  const stateDir = configDir();
  await stopBridgeDaemon(stateDir).catch(() => {});
  const info = await startBridgeDaemon({
    stateDir,
    cliPath: process.argv[1] ?? "",
    nodePath: process.execPath,
    env: process.env,
    cwd: process.cwd(),
  });
  console.log(`Epoch Bridge restarted (pid ${info.pid}). Logs: ${info.logPath}`);
}
