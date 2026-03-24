import process from "node:process";
import path from "node:path";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { readHubDaemonInfo, startHubDaemon, stopHubDaemon, isProcessRunning } from "../daemon.js";
import { connectDb, runMigrations } from "../db/db.js";
import { startHub } from "../server.js";

function hasFlag(argv: string[], flag: string) {
  return argv.includes(flag);
}

export async function startCommand(argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  if (!config) {
    throw new Error("Epoch config missing. Run: epoch init");
  }

  const foreground = hasFlag(argv, "--foreground") || hasFlag(argv, "-f");
  if (!foreground) {
    const existing = await readHubDaemonInfo(stateDir);
    if (existing && Number.isFinite(existing.pid) && existing.pid > 1 && isProcessRunning(existing.pid)) {
      console.log(`Epoch already running (pid ${existing.pid}).`);
      return;
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

    console.log(`Epoch started (pid ${info.pid}). Logs: ${info.logPath}`);
    return;
  }

  const dbPath = process.env.EPOCH_DB_PATH ?? path.join(stateDir, "epoch.sqlite");

  const pool = await connectDb(dbPath);
  await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });

  const port = Number(process.env.EPOCH_PORT ?? "8787");
  const host = process.env.EPOCH_HOST ?? "0.0.0.0";

  const hub = await startHub({
    port,
    host,
    config,
    stateDir,
    pool,
  });

  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    try {
      await hub.close();
    } finally {
      await pool.end().catch(() => {});
      process.exit(0);
    }
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);

  // Keep process alive.
  await new Promise(() => {});
}
