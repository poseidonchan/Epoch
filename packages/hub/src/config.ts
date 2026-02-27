import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { randomBytes } from "node:crypto";

import { v4 as uuidv4 } from "uuid";

export type HubAiAuthConfig =
  | { type: "none" }
  | { type: "api_key"; provider: string; apiKey: string }
  | { type: "oauth"; oauthProviderId: string; credentials: { refresh: string; access: string; expires: number; [key: string]: unknown } };

export type HubAiConfig = {
  provider: string;
  defaultModelId: string | null;
  auth: HubAiAuthConfig;
};

export type HubConfig = {
  serverId: string;
  token: string;
  createdAt: string;
  ai?: HubAiConfig;
  openaiSettings?: {
    ocrModel?: string;
  };
  providerApiKeys?: Record<string, string>;
  providerApiKeyMetadata?: Record<
    string,
    {
      updatedAt?: string;
      source?: string;
    }
  >;
};

export function getStateDir(): string {
  return process.env.LABOS_STATE_DIR ?? path.join(os.homedir(), ".labos");
}

export async function ensureStateDir(stateDir: string) {
  await mkdir(stateDir, { recursive: true });
}

function configPath(stateDir: string) {
  return path.join(stateDir, "config.json");
}

export async function saveHubConfig(opts: { stateDir: string; config: HubConfig }) {
  await ensureStateDir(opts.stateDir);
  const cfgPath = configPath(opts.stateDir);
  await writeFile(cfgPath, JSON.stringify(opts.config, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await chmod(cfgPath, 0o600).catch(() => {
    // best-effort
  });
}

export async function loadOrCreateHubConfig(opts: { stateDir: string; allowCreate: boolean }): Promise<HubConfig | null> {
  const cfgPath = configPath(opts.stateDir);
  try {
    const raw = await readFile(cfgPath, "utf8");
    const parsed = JSON.parse(raw) as HubConfig;
    // Ensure token file isn't world-readable (best-effort).
    await chmod(cfgPath, 0o600).catch(() => {
      // ignore
    });
    return parsed;
  } catch (err) {
    const code = (err as any)?.code;
    if (code && code !== "ENOENT") {
      throw err;
    }
    if (!opts.allowCreate) {
      return null;
    }

    const token = randomBytes(32).toString("base64url");
    const config: HubConfig = {
      serverId: uuidv4(),
      token,
      createdAt: new Date().toISOString(),
    };
    await saveHubConfig({ stateDir: opts.stateDir, config });
    return config;
  }
}
