import process from "node:process";

import type { HubConfig } from "./config.js";

export const HUB_DEFAULT_PROVIDER = "openai-codex";
export const HUB_DEFAULT_MODEL_ID = "gpt-5.3-codex";

export function hubDefaultModelRef() {
  return `${HUB_DEFAULT_PROVIDER}/${HUB_DEFAULT_MODEL_ID}`;
}

// ---------------------------------------------------------------------------
// Environment-based API key lookup (replaces @mariozechner/pi-ai getEnvApiKey)
// ---------------------------------------------------------------------------

const ENV_KEY_MAP: Record<string, string[]> = {
  openai: ["OPENAI_API_KEY"],
  "openai-codex": ["OPENAI_API_KEY"],
  anthropic: ["ANTHROPIC_API_KEY"],
  "google-gemini-cli": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
  "google-antigravity": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
  "github-copilot": ["GITHUB_TOKEN"],
};

export function getEnvApiKey(provider: string): string | undefined {
  for (const envVar of ENV_KEY_MAP[provider] ?? []) {
    const val = process.env[envVar];
    if (val) return val;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Hardcoded model registry — fallback only.
// The primary path fetches models dynamically from the Codex app-server via
// engine.modelList(). This registry is used only when the engine is
// unavailable (e.g. during startup or if the app-server process crashes).
// ---------------------------------------------------------------------------

const MODEL_REGISTRY: Record<string, Array<{ id: string; name: string; reasoning: boolean }>> = {
  "openai-codex": [
    { id: "gpt-5.3-codex", name: "GPT-5.3 Codex", reasoning: true },
    { id: "codex-mini-2025-01-24", name: "Codex Mini", reasoning: true },
    { id: "o4-mini", name: "o4-mini", reasoning: true },
    { id: "o3", name: "o3", reasoning: true },
    { id: "gpt-4.1", name: "GPT-4.1", reasoning: false },
  ],
  anthropic: [
    { id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", reasoning: true },
    { id: "claude-opus-4-6", name: "Claude Opus 4.6", reasoning: true },
    { id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", reasoning: false },
  ],
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type HubModelResolution =
  | {
      ok: true;
      ref: string;
      provider: string;
      modelId: string;
      hasApiKey: boolean;
    }
  | {
      ok: false;
      ref: string | null;
      reason: "missing_ref" | "bad_ref";
      message: string;
      provider?: string;
      modelId?: string;
      hasApiKey?: boolean;
    };

export type HubProviderResolution = {
  provider: string;
  defaultModelId: string | null;
  ref: string | null;
  hasApiKey: boolean;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function oauthProviderToModelProvider(oauthProviderId: string): string | null {
  switch (oauthProviderId) {
    case "openai-codex":
      return "openai-codex";
    case "anthropic":
      return "anthropic";
    case "github-copilot":
      return "github-copilot";
    case "google-gemini-cli":
      return "google-gemini-cli";
    case "google-antigravity":
      return "google-antigravity";
    default:
      return null;
  }
}

function hasConfiguredCredentials(config: HubConfig | null | undefined, provider: string): boolean {
  const ai = config?.ai;
  const auth = ai?.auth;
  if (auth?.type === "api_key") {
    return auth.provider === provider && Boolean(auth.apiKey);
  }
  if (auth?.type === "oauth") {
    const modelProvider = oauthProviderToModelProvider(auth.oauthProviderId);
    const access = (auth.credentials as any)?.access;
    return modelProvider === provider && typeof access === "string" && access.length > 0;
  }
  return false;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export function resolveHubProvider(config?: HubConfig | null): HubProviderResolution {
  const ai = config?.ai;
  if (ai?.provider) {
    const provider = String(ai.provider).trim() || HUB_DEFAULT_PROVIDER;
    const defaultModelId = ai.defaultModelId ? String(ai.defaultModelId).trim() : null;
    const hasApiKey = hasConfiguredCredentials(config, provider) || Boolean(getEnvApiKey(provider));
    return {
      provider,
      defaultModelId: defaultModelId || null,
      ref: defaultModelId ? `${provider}/${defaultModelId}` : `${provider}/(default)`,
      hasApiKey,
    };
  }

  const refRaw = process.env.LABOS_MODEL_PRIMARY ?? process.env.LABOS_MODEL ?? null;
  const ref = refRaw ? String(refRaw).trim() : null;
  if (!ref) {
    const provider = HUB_DEFAULT_PROVIDER;
    const defaultModelId = HUB_DEFAULT_MODEL_ID;
    return { provider, defaultModelId, ref: `${provider}/${defaultModelId}`, hasApiKey: Boolean(getEnvApiKey(provider)) };
  }

  const idx = ref.indexOf("/");
  const provider = (idx === -1 ? HUB_DEFAULT_PROVIDER : ref.slice(0, idx)).trim();
  const modelId = (idx === -1 ? ref : ref.slice(idx + 1)).trim();
  const hasApiKey = Boolean(getEnvApiKey(provider));
  return { provider: provider || HUB_DEFAULT_PROVIDER, defaultModelId: modelId || null, ref, hasApiKey };
}

export function listHubModelsForProvider(provider: string): Array<{ id: string; name: string; reasoning: boolean }> {
  return MODEL_REGISTRY[provider] ?? [];
}

export function resolveHubModel(config?: HubConfig | null): HubModelResolution {
  const ai = config?.ai;
  if (ai?.provider) {
    const provider = String(ai.provider).trim() || HUB_DEFAULT_PROVIDER;
    const modelId = String(ai.defaultModelId ?? "").trim();
    if (!modelId) {
      return { ok: false, ref: `${provider}/(default)`, reason: "missing_ref", message: "Missing default model id. Run: labos-hub config" };
    }
    const hasApiKey = hasConfiguredCredentials(config, provider) || Boolean(getEnvApiKey(provider));
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, hasApiKey };
  }

  const refRaw = process.env.LABOS_MODEL_PRIMARY ?? process.env.LABOS_MODEL ?? null;
  if (!refRaw) {
    const provider = HUB_DEFAULT_PROVIDER;
    const modelId = HUB_DEFAULT_MODEL_ID;
    const hasApiKey = Boolean(getEnvApiKey(provider));
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, hasApiKey };
  }

  const ref = String(refRaw).trim();
  if (!ref) {
    return { ok: false, ref: null, reason: "missing_ref", message: "Missing model config. Run: labos-hub config" };
  }

  const idx = ref.indexOf("/");
  const provider = (idx === -1 ? HUB_DEFAULT_PROVIDER : ref.slice(0, idx)).trim();
  const modelId = (idx === -1 ? ref : ref.slice(idx + 1)).trim();
  if (!provider || !modelId) {
    return { ok: false, ref, reason: "bad_ref", message: `Invalid model ref: ${ref}` };
  }

  const hasApiKey = hasConfiguredCredentials(config, provider) || Boolean(getEnvApiKey(provider));
  return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, hasApiKey };
}
