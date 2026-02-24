import { loadConfig } from "../config.js";
import { BridgeService } from "../service.js";

export async function startCommand(_argv: string[]) {
  const cfg = await loadConfig();
  if (!cfg) {
    throw new Error("Config missing. Run: labos-hpc-bridge pair ...");
  }

  const service = new BridgeService(cfg);
  await service.start();
}

