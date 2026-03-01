import process from "node:process";
import path from "node:path";

import { ensureStateDir, getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";
import { buildHubPairingPayloadURL, renderHubPairingQRCode, resolvePairingWSURL } from "./pair_qr.js";
import { configCommand } from "./config.js";
import { startCommand } from "./start.js";
import { createWizardPrompter, createWizardUI } from "./wizard_ui.js";

export async function initCommand(_argv: string[]) {
  const ui = createWizardUI();
  const prompter = createWizardPrompter(ui);
  try {
    ui.banner("LabOS Hub Initialization", "Create state/config, run migrations, and print pairing QR");

    const stateDir = getStateDir();
    await ensureStateDir(stateDir);
    ui.step(1, 4, "Create or load Hub state directory", "ok");

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
    ui.step(2, 4, "Database migrations", "ok");

    ui.step(3, 4, "Hub config + token ready", "ok");
    ui.keyValue("State dir", stateDir);
    ui.keyValue("DB", dbPath);
    ui.keyValue("Server ID", config.serverId);
    ui.keyValue("Shared token (store this)", config.token);
    const pairingWS = resolvePairingWSURL({ env: process.env, defaultPort: 8787 });
    const pairingPayloadURL = buildHubPairingPayloadURL({
      wsURL: pairingWS.wsURL,
      token: config.token,
      serverId: config.serverId,
    });
    ui.line();
    ui.step(4, 4, "Pairing QR generated", "ok");
    ui.line("Scan this in LabOS iPhone app Settings > Gateway > Scan Hub QR");
    ui.keyValue("Pairing WS URL", pairingWS.wsURL);
    if (pairingWS.warning) {
      ui.warn(pairingWS.warning);
    }
    renderHubPairingQRCode(pairingPayloadURL, (line) => console.log(line));
    ui.line("Pairing URL (fallback):");
    ui.line(pairingPayloadURL);

    if (!prompter.interactive) {
      ui.note("Next: run `labos-hub config` to set codex defaults and optional OPENAI_API_KEY for file embeddings.");
      return;
    }

    const runConfig = await prompter.confirm({
      message: "Run `labos-hub config` now?",
      defaultYes: true,
    });
    if (runConfig) {
      ui.line();
      await configCommand([], { ui, prompter });
    }

    const startNow = await prompter.confirm({
      message: "Start LabOS Hub now?",
      defaultYes: true,
    });
    if (startNow) {
      await startCommand([]);
    } else {
      ui.note("Next: run `labos-hub start` when ready.");
    }
  } finally {
    prompter.close();
  }
}
