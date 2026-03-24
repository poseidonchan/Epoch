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

export type HubPushConfig = {
  teamId: string;
  keyId: string;
  bundleId: string;
  encryptedKeyPath: string;
  configuredAt?: string;
};

export type HubConfig = {
  serverId: string;
  token: string;
  createdAt: string;
  displayName?: string;
  workspaceRoot?: string;
  publicWsUrl?: string | null;
  push?: HubPushConfig | null;
  pushRelayUrl?: string | null;
  pushRelaySharedSecret?: string | null;
  pushEnabled?: boolean;
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
  return process.env.EPOCH_STATE_DIR ?? path.join(os.homedir(), ".epoch");
}

export function defaultWorkspaceRoot(stateDir: string): string {
  return path.join(stateDir, "workspace");
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
    const parsed = normalizeHubConfig(JSON.parse(raw) as HubConfig, opts.stateDir);
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
    const legacyBridge = await readLegacyBridgeConfig();
    const config: HubConfig = normalizeHubConfig({
      serverId: uuidv4(),
      token,
      createdAt: new Date().toISOString(),
      displayName: os.hostname(),
      workspaceRoot: legacyBridge?.workspaceRoot,
      publicWsUrl: null,
      push: null,
      pushRelayUrl: null,
      pushRelaySharedSecret: null,
      pushEnabled: false,
    }, opts.stateDir);
    await saveHubConfig({ stateDir: opts.stateDir, config });
    return config;
  }
}

export function resolveConfiguredWorkspaceRoot(args: {
  stateDir: string;
  config?: HubConfig | null;
  env?: NodeJS.ProcessEnv;
}): string {
  const env = args.env ?? process.env;
  return normalizeOptionalString(env.EPOCH_WORKSPACE_ROOT)
    ?? normalizeOptionalString(env.EPOCH_HPC_WORKSPACE_ROOT)
    ?? normalizeOptionalString(args.config?.workspaceRoot)
    ?? defaultWorkspaceRoot(args.stateDir);
}

export function resolveConfiguredPublicWsUrl(args: {
  config?: HubConfig | null;
  env?: NodeJS.ProcessEnv;
}): string | null {
  const env = args.env ?? process.env;
  return normalizeOptionalString(env.EPOCH_PAIR_WS_URL)
    ?? normalizeOptionalString(args.config?.publicWsUrl)
    ?? null;
}

function normalizeHubConfig(config: HubConfig, stateDir: string): HubConfig {
  return {
    ...config,
    displayName: normalizeOptionalString(config.displayName) ?? os.hostname(),
    workspaceRoot: resolveConfiguredWorkspaceRoot({ stateDir, config, env: {} }),
    publicWsUrl: normalizeOptionalString(config.publicWsUrl) ?? null,
    push: normalizeHubPushConfig(config.push),
    pushRelayUrl: normalizeOptionalString(config.pushRelayUrl) ?? null,
    pushRelaySharedSecret: normalizeOptionalString(config.pushRelaySharedSecret) ?? null,
    pushEnabled: config.pushEnabled === true,
  };
}

async function readLegacyBridgeConfig(): Promise<{ workspaceRoot?: string } | null> {
  const legacyPath = path.join(os.homedir(), ".epoch-bridge", "config.json");
  try {
    const raw = JSON.parse(await readFile(legacyPath, "utf8")) as Record<string, unknown>;
    return {
      workspaceRoot: normalizeOptionalString(raw.workspaceRoot) ?? undefined,
    };
  } catch {
    return null;
  }
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeHubPushConfig(value: HubConfig["push"]): HubPushConfig | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const teamId = normalizeOptionalString(value.teamId);
  const keyId = normalizeOptionalString(value.keyId);
  const bundleId = normalizeOptionalString(value.bundleId);
  const encryptedKeyPath = normalizeOptionalString(value.encryptedKeyPath);
  if (!teamId || !keyId || !bundleId || !encryptedKeyPath) {
    return null;
  }
  return {
    teamId,
    keyId,
    bundleId,
    encryptedKeyPath,
    configuredAt: normalizeOptionalString(value.configuredAt) ?? undefined,
  };
}
