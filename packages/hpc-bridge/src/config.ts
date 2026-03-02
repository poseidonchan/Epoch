import os from "node:os";
import path from "node:path";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";

import { v4 as uuidv4 } from "uuid";

export type BridgeConfig = {
  hubUrl: string;
  token: string;
  nodeId: string;
  workspaceRoot: string;
  defaults: {
    partition?: string;
    account?: string;
    qos?: string;
    timeLimitMinutes?: number;
    cpus?: number;
    memMB?: number;
    gpus?: number;
  };
};

export function configDir(): string {
  return path.join(os.homedir(), ".epoch-bridge");
}

export function configPath(): string {
  return path.join(configDir(), "config.json");
}

export async function loadConfig(): Promise<BridgeConfig | null> {
  try {
    const raw = await readFile(configPath(), "utf8");
    return JSON.parse(raw) as BridgeConfig;
  } catch {
    return null;
  }
}

export async function saveConfig(cfg: Omit<BridgeConfig, "nodeId"> & { nodeId?: string }) {
  await mkdir(configDir(), { recursive: true });
  const final: BridgeConfig = { ...cfg, nodeId: cfg.nodeId ?? uuidv4() };
  await writeFile(configPath(), JSON.stringify(final, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await chmod(configPath(), 0o600).catch(() => {
    // best effort
  });
  return final;
}
