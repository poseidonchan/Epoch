import process from "node:process";
import path from "node:path";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";
import { resolveHubModel } from "../model.js";

export async function doctorCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });

  const dbPath = process.env.LABOS_DB_PATH ?? path.join(stateDir, "labos.sqlite");
  const modelResolved = resolveHubModel(config);
  console.log(`State dir: ${stateDir}`);
  console.log(`Config: ${config ? "present" : "missing (run labos-hub init)"}`);
  console.log(`DB: ${dbPath}`);
  if (modelResolved.ok) {
    console.log(`Model: ${modelResolved.ref}${modelResolved.hasApiKey ? "" : " (no credentials detected; run labos-hub config)"}`);
  } else {
    console.log(`Model: ${modelResolved.ref ?? "missing"} (${modelResolved.message})`);
  }

  if (!config) {
    process.exitCode = 1;
    return;
  }

  const pool = await connectDb(dbPath);
  try {
    await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    console.log("DB migrations: ok");
  } finally {
    await pool.end();
  }
}
