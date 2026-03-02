import process from "node:process";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { startHubDaemon, stopHubDaemon } from "../daemon.js";

export async function restartCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  if (!config) {
    throw new Error("Hub config missing. Run: epoch-hub init");
  }

  await stopHubDaemon(stateDir).catch(() => {});

  const port = Number(process.env.EPOCH_PORT ?? "8787");
  const host = process.env.EPOCH_HOST ?? "0.0.0.0";

  const info = await startHubDaemon({
    stateDir,
    cliPath: process.argv[1] ?? "",
    nodePath: process.execPath,
    host,
    port,
    env: process.env,
    cwd: process.cwd(),
  });

  console.log(`Epoch Hub restarted (pid ${info.pid}). Logs: ${info.logPath}`);
}
