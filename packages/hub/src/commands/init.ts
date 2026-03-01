import process from "node:process";
import path from "node:path";

import { ensureStateDir, getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";
import { buildHubPairingPayloadURL, renderHubPairingQRCode, resolvePairingWSURL } from "./pair_qr.js";

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
  const pairingWS = resolvePairingWSURL({ env: process.env, defaultPort: 8787 });
  const pairingPayloadURL = buildHubPairingPayloadURL({
    wsURL: pairingWS.wsURL,
    token: config.token,
    serverId: config.serverId,
  });
  console.log("");
  console.log("Scan this in LabOS iPhone app Settings > Gateway > Scan Hub QR");
  console.log(`Pairing WS URL: ${pairingWS.wsURL}`);
  if (pairingWS.warning) {
    console.log(`Warning: ${pairingWS.warning}`);
  }
  renderHubPairingQRCode(pairingPayloadURL, (line) => console.log(line));
  console.log("Pairing URL (fallback):");
  console.log(pairingPayloadURL);
  console.log("Next: run `labos-hub config` to set codex defaults and optional OPENAI_API_KEY for file embeddings.");
}
