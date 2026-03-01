import { configDir } from "../config.js";
import { stopBridgeDaemon } from "../daemon.js";

export async function stopCommand(_argv: string[]) {
  const stateDir = configDir();
  const result = await stopBridgeDaemon(stateDir).catch(() => ({ stopped: false as const }));
  if (result.stopped) {
    const pidPart = result.pid ? ` (pid ${result.pid})` : "";
    console.log(`LabOS HPC Bridge stopped${pidPart}.`);
    return;
  }
  console.log("No running LabOS HPC Bridge daemon found (already stopped).");
}
