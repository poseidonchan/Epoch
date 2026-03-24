import process from "node:process";
import path from "node:path";

import { APNsSilentPushSender, type SilentPushSender } from "@epoch/push-relay";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { readHubDaemonInfo, startHubDaemon, stopHubDaemon, isProcessRunning } from "../daemon.js";
import { connectDb, runMigrations } from "../db/db.js";
import { decryptEncryptedApnsKey } from "../push_secrets.js";
import { startHub } from "../server.js";
import { createWizardPrompter, createWizardUI } from "./wizard_ui.js";
import { encodePushUnlockPayload, resolvePushUnlockPassphrase } from "./push_setup.js";

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
    const pushUnlockPayload = await promptForPushUnlockPayload({
      stateDir,
      config,
      argv,
    });

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

    console.log(`Epoch started (pid ${info.pid}). Logs: ${info.logPath}`);
    return;
  }

  const dbPath = process.env.EPOCH_DB_PATH ?? path.join(stateDir, "epoch.sqlite");

  const pool = await connectDb(dbPath);
  await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
  const pushSender = await createPushSenderForStart({
    stateDir,
    config,
    argv,
  });

  const port = Number(process.env.EPOCH_PORT ?? "8787");
  const host = process.env.EPOCH_HOST ?? "0.0.0.0";

  const hub = await startHub({
    port,
    host,
    config,
    stateDir,
    pool,
    pushSender,
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

async function promptForPushUnlockPayload(args: {
  stateDir: string;
  config: NonNullable<Awaited<ReturnType<typeof loadOrCreateHubConfig>>>;
  argv: string[];
}): Promise<string | null> {
  const ui = createWizardUI();
  const prompter = createWizardPrompter(ui);
  try {
    const passphrase = await resolvePushUnlockPassphrase({
      config: args.config,
      ui,
      prompter,
      argv: args.argv,
    });
    return passphrase ? encodePushUnlockPayload(passphrase) : null;
  } finally {
    prompter.close();
  }
}

async function createPushSenderForStart(args: {
  stateDir: string;
  config: NonNullable<Awaited<ReturnType<typeof loadOrCreateHubConfig>>>;
  argv: string[];
}): Promise<SilentPushSender | null> {
  if (args.config.pushEnabled !== true || !args.config.push) {
    return null;
  }

  const ui = createWizardUI();
  const prompter = createWizardPrompter(ui);
  try {
    const passphrase = await resolvePushUnlockPassphrase({
      config: args.config,
      ui,
      prompter,
      argv: args.argv,
    });
    if (!passphrase) {
      return null;
    }
    const privateKeyPem = await decryptEncryptedApnsKey({
      encryptedKeyPath: args.config.push.encryptedKeyPath,
      passphrase,
    });
    return new APNsSilentPushSender({
      teamId: args.config.push.teamId,
      keyId: args.config.push.keyId,
      bundleId: args.config.push.bundleId,
      privateKeyPem,
    });
  } finally {
    prompter.close();
  }
}
