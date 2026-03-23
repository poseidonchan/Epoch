import process from "node:process";
import path from "node:path";

import { ensureStateDir, getStateDir, loadOrCreateHubConfig, saveHubConfig } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";
import { buildHubPairingPayloadURL, renderHubPairingQRCode, resolvePairingWSURL } from "./pair_qr.js";
import { configCommand } from "./config.js";
import { startCommand } from "./start.js";
import { createWizardPrompter, createWizardUI } from "./wizard_ui.js";

export async function initCommand(_argv: string[]) {
  const ui = createWizardUI();
  const prompter = createWizardPrompter(ui);
  try {
    ui.banner("Epoch Server Initialization", "Create local state, prepare direct pairing, and print the Epoch QR");

    const stateDir = getStateDir();
    await ensureStateDir(stateDir);
    ui.step(1, 4, "Create or load Epoch state directory", "ok");

    const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
    if (!config) {
      throw new Error("Failed to create Epoch config");
    }

    const dbPath = process.env.EPOCH_DB_PATH ?? path.join(stateDir, "epoch.sqlite");

    const pool = await connectDb(dbPath);
    try {
      await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    } finally {
      await pool.end();
    }
    ui.step(2, 4, "Database migrations", "ok");

    const pairingWS = await resolvePairingWSURL({ env: process.env, config, defaultPort: 8787 });
    if (!config.publicWsUrl && pairingWS.source === "tailscale") {
      config.publicWsUrl = pairingWS.wsURL;
      await saveHubConfig({ stateDir, config });
    }

    ui.step(3, 4, "Server config + token ready", "ok");
    ui.keyValue("State dir", stateDir);
    ui.keyValue("DB", dbPath);
    ui.keyValue("Server ID", config.serverId);
    ui.keyValue("Display Name", config.displayName ?? "not configured");
    ui.keyValue("Shared token (store this)", config.token);
    const pairingPayloadURL = buildHubPairingPayloadURL({
      wsURL: pairingWS.wsURL,
      token: config.token,
      serverId: config.serverId,
      name: config.displayName,
    });
    ui.line();
    ui.step(4, 4, "Pairing QR generated", "ok");
    ui.line("Scan this in EpochApp > Settings > Servers > Scan Epoch QR");
    ui.keyValue("Pairing WS URL", pairingWS.wsURL);
    ui.keyValue("Pairing Source", pairingWS.source);
    if (pairingWS.warning) {
      ui.warn(pairingWS.warning);
    }
    ui.keyValue("Default workspace root", config.workspaceRoot ?? "not configured");
    renderHubPairingQRCode(pairingPayloadURL, (line) => console.log(line));
    ui.line("Pairing URL (fallback):");
    ui.line(pairingPayloadURL);

    if (!prompter.interactive) {
      ui.note("Next: run `epoch config` to set display name, pairing WS URL, workspace root, and optional OPENAI_API_KEY.");
      return;
    }

    const runConfig = await prompter.confirm({
      message: "Run `epoch config` now?",
      defaultYes: true,
    });
    if (runConfig) {
      ui.line();
      await configCommand([], { ui, prompter });
    }

    const startNow = await prompter.confirm({
      message: "Start Epoch now?",
      defaultYes: true,
    });
    if (startNow) {
      await startCommand([]);
    } else {
      ui.note("Next: run `epoch start` when ready.");
    }
  } finally {
    prompter.close();
  }
}
