import { configDir, loadConfig } from "../config.js";
import { isProcessRunning, readBridgeDaemonInfo } from "../daemon.js";

export async function statusCommand(_argv: string[]) {
  const cfg = await loadConfig();
  if (!cfg) {
    console.log("No config found. Run: labos-hpc-bridge config (or pair) ...");
    return;
  }

  const stateDir = configDir();
  const daemonInfo = await readBridgeDaemonInfo(stateDir);
  const running = Boolean(daemonInfo && daemonInfo.pid > 1 && isProcessRunning(daemonInfo.pid));

  console.log("LabOS HPC Bridge config:");
  console.log(`- hubUrl: ${cfg.hubUrl}`);
  console.log(`- nodeId: ${cfg.nodeId}`);
  console.log(`- workspaceRoot: ${cfg.workspaceRoot}`);
  console.log(`- defaults: ${JSON.stringify(cfg.defaults)}`);
  console.log(`- daemon: ${running ? `running (pid ${daemonInfo?.pid})` : "stopped"}`);
  if (daemonInfo?.logPath) {
    console.log(`- logPath: ${daemonInfo.logPath}`);
  }
}
