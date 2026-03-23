import process from "node:process";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { startHubDaemon, stopHubDaemon } from "../daemon.js";
import { createWizardPrompter, createWizardUI } from "./wizard_ui.js";
import { encodePushUnlockPayload, resolvePushUnlockPassphrase } from "./push_setup.js";

export async function restartCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  if (!config) {
    throw new Error("Epoch config missing. Run: epoch init");
  }

  await stopHubDaemon(stateDir).catch(() => {});
  const pushUnlockPayload = await promptForPushUnlockPayload(config);

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
    stdinPayload: pushUnlockPayload,
    extraArgs: pushUnlockPayload ? ["--apns-unlock-from-stdin"] : [],
  });

  console.log(`Epoch restarted (pid ${info.pid}). Logs: ${info.logPath}`);
}

async function promptForPushUnlockPayload(config: NonNullable<Awaited<ReturnType<typeof loadOrCreateHubConfig>>>) {
  const ui = createWizardUI();
  const prompter = createWizardPrompter(ui);
  try {
    const passphrase = await resolvePushUnlockPassphrase({
      config,
      ui,
      prompter,
      argv: [],
    });
    return passphrase ? encodePushUnlockPayload(passphrase) : null;
  } finally {
    prompter.close();
  }
}
