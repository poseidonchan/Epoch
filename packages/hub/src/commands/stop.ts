import { getStateDir } from "../config.js";
import { stopHubDaemon } from "../daemon.js";

export async function stopCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const result = await stopHubDaemon(stateDir).catch(() => ({ stopped: false as const }));

  if (result.stopped) {
    const pidPart = result.pid ? ` (pid ${result.pid})` : "";
    console.log(`Epoch server stopped${pidPart}.`);
    return;
  }

  console.log("No running Epoch server daemon found (already stopped).");
}
