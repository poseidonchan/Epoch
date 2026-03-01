import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { isProcessRunning, readHubDaemonInfo } from "../daemon.js";
import { createWizardUI } from "./wizard_ui.js";

export async function statusCommand(_argv: string[]) {
  const ui = createWizardUI();
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  const daemonInfo = await readHubDaemonInfo(stateDir);
  const running = Boolean(daemonInfo && daemonInfo.pid > 1 && isProcessRunning(daemonInfo.pid));

  ui.banner("LabOS Hub Status");
  ui.step(1, 1, "Read configuration and daemon status", "ok");
  ui.keyValue("State dir", stateDir);
  ui.keyValue("Config", config ? "present" : "missing (run labos-hub init)");
  ui.keyValue("Server ID", config?.serverId ?? "not configured");
  ui.keyValue("Shared token", config?.token ? "configured" : "not configured");
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
}
