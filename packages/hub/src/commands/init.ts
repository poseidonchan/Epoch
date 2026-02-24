import process from "node:process";
import path from "node:path";

import { ensureStateDir, getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";

export async function initCommand(_argv: string[]) {
  const stateDir = getStateDir();
  await ensureStateDir(stateDir);

  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
  if (!config) {
    throw new Error("Failed to create hub config");
  }

  const dbPath = process.env.LABOS_DB_PATH ?? path.join(stateDir, "labos.sqlite");

  const pool = await connectDb(dbPath);
  try {
    await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
  } finally {
    await pool.end();
  }

  console.log("LabOS Hub initialized.");
  console.log(`State dir: ${stateDir}`);
  console.log(`DB: ${dbPath}`);
  console.log(`Server ID: ${config.serverId}`);
  console.log(`Shared token (store this): ${config.token}`);
  console.log("Next: run `labos-hub config` to set up provider + model (or use env vars).");
}
