import process from "node:process";

import type { HubConfig } from "../config.js";
import { importEncryptedApnsKey, readPushKeyStatus } from "../push_secrets.js";
import type { WizardPrompter, WizardUI } from "./wizard_ui.js";

export type PushSetupSummary = {
  enabled: boolean;
  configured: boolean;
  bundleId: string | null;
  encryptedKeyPath: string | null;
  encryptedKeyPresent: boolean;
  encryptedKeyPrivate: boolean;
};

export async function configureBackgroundPush(args: {
  stateDir: string;
  config: HubConfig;
  ui: WizardUI;
  prompter: WizardPrompter;
  defaultYes?: boolean;
}) {
  const summary = await summarizeBackgroundPush({
    stateDir: args.stateDir,
    config: args.config,
  });

  args.ui.line("Background push lets EpochApp wake back up and keep live Codex sessions synced while the app is backgrounded.");
  args.ui.line("Epoch only sends a minimal silent-push payload: serverId, cursorHint, changedSessionIds, and a reason.");
  args.ui.line("Thread content does not go into APNs. The phone still reconnects and pulls the real data from Epoch.");
  args.ui.warn(
    "If someone can read this account's Epoch process memory while push is unlocked, they can abuse this server's APNs signing ability."
  );
  args.ui.note("The APNs private key will be encrypted into ~/.epoch/secrets/ and will not be written into config.json.");
  args.ui.line();

  const wantsPush = await args.prompter.confirm({
    message: summary.configured
      ? "Reconfigure background push for live Codex keepalive now?"
      : "Enable background push for live Codex keepalive?",
    defaultYes: args.defaultYes ?? summary.enabled,
  });

  if (!wantsPush) {
    args.config.pushEnabled = false;
    return { configured: false };
  }

  const teamId = await args.prompter.input({
    message: "Apple Developer Team ID:",
    defaultValue: args.config.push?.teamId ?? "",
  });
  const keyId = await args.prompter.input({
    message: "APNs Key ID:",
    defaultValue: args.config.push?.keyId ?? "",
  });
  const bundleId = await args.prompter.input({
    message: "EpochApp bundle identifier for push topic:",
    defaultValue: args.config.push?.bundleId ?? "",
  });
  const sourcePath = await args.prompter.input({
    message: "Path to the APNs .p8 private key:",
    defaultValue: "",
  });
  const passphrase = await promptForNewUnlockPassphrase(args.prompter);

  const imported = await importEncryptedApnsKey({
    stateDir: args.stateDir,
    sourcePath,
    passphrase,
    destinationPath: args.config.push?.encryptedKeyPath ?? null,
  });

  args.config.pushEnabled = true;
  args.config.push = {
    teamId: teamId.trim(),
    keyId: keyId.trim(),
    bundleId: bundleId.trim(),
    encryptedKeyPath: imported.encryptedKeyPath,
    configuredAt: new Date().toISOString(),
  };
  args.config.pushRelayUrl = null;
  args.config.pushRelaySharedSecret = null;

  args.ui.success("Background push configured.");
  args.ui.note("`epoch start` will ask for the local unlock passphrase before enabling APNs for this running process.");
  return { configured: true };
}

export async function summarizeBackgroundPush(args: {
  stateDir: string;
  config: HubConfig;
}): Promise<PushSetupSummary> {
  const keyStatus = await readPushKeyStatus({
    stateDir: args.stateDir,
    config: args.config,
  });
  return {
    enabled: args.config.pushEnabled === true,
    configured: args.config.pushEnabled === true && args.config.push != null,
    bundleId: args.config.push?.bundleId ?? null,
    encryptedKeyPath: keyStatus.encryptedKeyPath,
    encryptedKeyPresent: keyStatus.exists,
    encryptedKeyPrivate: keyStatus.privatePermissions,
  };
}

export async function resolvePushUnlockPassphrase(args: {
  config: HubConfig;
  ui: WizardUI;
  prompter: WizardPrompter;
  argv: string[];
}): Promise<string | null> {
  if (args.config.pushEnabled !== true || !args.config.push) {
    return null;
  }

  if (args.argv.includes("--apns-unlock-from-stdin")) {
    return await readPassphraseFromStdin();
  }

  if (!args.prompter.interactive) {
    throw new Error("Background push is enabled. Run `epoch start` interactively so Epoch can unlock the encrypted APNs key.");
  }

  args.ui.line("Background push is enabled for this Epoch server.");
  args.ui.line("Epoch needs your local unlock passphrase to decrypt the APNs signing key into memory for this process.");
  args.ui.line("This enables silent push so EpochApp can wake up and continue syncing live Codex sessions in the background.");
  args.ui.warn("The unlock passphrase itself is not saved back to config.json, but the unlocked key will live in this Epoch process memory.");
  args.ui.line();

  return await args.prompter.secret({
    message: "Local unlock passphrase:",
    allowEmpty: false,
  });
}

export function encodePushUnlockPayload(passphrase: string): string {
  return JSON.stringify({ passphrase }) + "\n";
}

async function promptForNewUnlockPassphrase(prompter: WizardPrompter): Promise<string> {
  while (true) {
    const first = await prompter.secret({
      message: "Set a local unlock passphrase for this APNs key:",
      allowEmpty: false,
    });
    const second = await prompter.secret({
      message: "Confirm the local unlock passphrase:",
      allowEmpty: false,
    });
    if (first === second) {
      return first;
    }
    process.stdout.write("Passphrases did not match. Please try again.\n");
  }
}

async function readPassphraseFromStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(String(chunk)));
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  const parsed = JSON.parse(raw) as { passphrase?: unknown };
  const passphrase = typeof parsed.passphrase === "string" ? parsed.passphrase.trim() : "";
  if (!passphrase) {
    throw new Error("Missing APNs unlock passphrase on stdin.");
  }
  return passphrase;
}
