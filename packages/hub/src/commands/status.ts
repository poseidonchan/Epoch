import process from "node:process";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { isProcessRunning, readHubDaemonInfo } from "../daemon.js";
import { readPushKeyStatus } from "../push_secrets.js";
import { buildHubPairingPayloadURL, renderHubPairingQRCode, resolvePairingWSURL } from "./pair_qr.js";
import { createWizardUI } from "./wizard_ui.js";

export async function statusCommand(argv: string[]) {
  const ui = createWizardUI();
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  const daemonInfo = await readHubDaemonInfo(stateDir);
  const running = Boolean(daemonInfo && daemonInfo.pid > 1 && isProcessRunning(daemonInfo.pid));
  const showQR = argv.includes("--qr");
  const pairingWS = config ? await resolvePairingWSURL({ env: process.env, config, defaultPort: 8787 }) : null;
  const pushKeyStatus = config ? await readPushKeyStatus({ stateDir, config }) : null;

  ui.banner("Epoch Server Status");
  ui.step(1, 1, "Read configuration and daemon status", "ok");
  ui.keyValue("State dir", stateDir);
  ui.keyValue("Config", config ? "present" : "missing (run epoch init)");
  ui.keyValue("Server ID", config?.serverId ?? "not configured");
  ui.keyValue("Display Name", config?.displayName ?? "not configured");
  ui.keyValue("Shared token", config?.token ? "configured" : "not configured");
  ui.keyValue("Workspace root", config?.workspaceRoot ?? "not configured");
  ui.keyValue("Pairing WS URL", pairingWS?.wsURL ?? "not configured");
  ui.keyValue("Pairing Source", pairingWS?.source ?? "not configured");
  ui.keyValue("Background push", config?.pushEnabled === true ? "enabled" : "disabled");
  ui.keyValue("Push topic", config?.push?.bundleId ?? "not configured");
  ui.keyValue("Encrypted APNs key", pushKeyStatus?.exists ? "present" : "missing");
  ui.keyValue("Unlock required on start", config?.pushEnabled === true ? "yes" : "no");
  ui.keyValue("Daemon", running ? `running (pid ${daemonInfo?.pid})` : "stopped");

  if (daemonInfo?.host) {
    ui.keyValue("Host", daemonInfo.host);
  }
  if (daemonInfo?.port != null) {
    ui.keyValue("Port", String(daemonInfo.port));
  }
  if (daemonInfo?.logPath) {
    ui.keyValue("Log path", daemonInfo.logPath);
  }

  if (pairingWS?.warning) {
    ui.warn(pairingWS.warning);
  }

  if (showQR && config?.token) {
    const payloadURL = buildHubPairingPayloadURL({
      wsURL: pairingWS?.wsURL ?? "",
      token: config.token,
      serverId: config.serverId,
      name: config.displayName,
    });
    ui.line();
    ui.line("Epoch pairing QR:");
    renderHubPairingQRCode(payloadURL, (line) => console.log(line));
    ui.line("Pairing URL (fallback):");
    ui.line(payloadURL);
  }
}
