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

  const refRaw = process.env.EPOCH_MODEL_PRIMARY ?? process.env.EPOCH_MODEL ?? null;
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

type ModelListCapableEngine = {
  name: string;
  modelList?: (params: Record<string, unknown>) => Promise<Record<string, unknown>>;
};

type ModelEngineResolver = {
  getEngine(name: string | null | undefined): Promise<ModelListCapableEngine>;
};

export type OperatorVisibleModel = {
  id: string;
  provider: string;
  name: string;
  reasoning: boolean;
  thinkingLevels: string[];
};

export type OperatorVisibleModelsSuccess = {
  ok: true;
  source: "codex-app-server";
  provider: string;
  defaultModelId: string;
  models: OperatorVisibleModel[];
  thinkingLevels: string[];
};

export type OperatorVisibleModelsFailure = {
  ok: false;
  code: "MODELS_UNAVAILABLE";
  message: string;
  data: {
    source: "codex-app-server";
    retryable: true;
    reason: "unreachable" | "unsupported" | "empty";
  };
};

export type OperatorVisibleModelsResult = OperatorVisibleModelsSuccess | OperatorVisibleModelsFailure;

export async function loadOperatorVisibleModels(args: {
  config?: HubConfig | null;
  engines: ModelEngineResolver;
}): Promise<OperatorVisibleModelsResult> {
  const resolved = resolveHubProvider(args.config);

  let engine: ModelListCapableEngine;
  try {
    engine = await args.engines.getEngine("codex-app-server");
  } catch {
    return operatorVisibleModelsUnavailable("unreachable");
  }

  if (!engine.modelList) {
    return operatorVisibleModelsUnavailable("unsupported");
  }

  try {
    const rawResult = await engine.modelList({});
    const rawData = Array.isArray((rawResult as { data?: unknown }).data)
      ? ((rawResult as { data?: unknown[] }).data ?? [])
      : [];
    const normalizedModels = rawData
      .map((entry) => normalizeOperatorVisibleModel(entry, resolved.provider))
      .filter((entry): entry is OperatorVisibleModel & { isDefault: boolean } => entry != null);

    if (normalizedModels.length === 0) {
      return operatorVisibleModelsUnavailable("empty");
    }

    let defaultModelId = normalizedModels.find((entry) => entry.isDefault)?.id ?? resolved.defaultModelId;
    if (!defaultModelId || !normalizedModels.some((entry) => entry.id === defaultModelId)) {
      defaultModelId = normalizedModels[0]?.id ?? "";
    }

    const provider = normalizedModels.find((entry) => entry.id === defaultModelId)?.provider
      ?? normalizedModels[0]?.provider
      ?? resolved.provider;
    const thinkingLevels = collectThinkingLevels(normalizedModels);

    return {
      ok: true,
      source: "codex-app-server",
      provider,
      defaultModelId,
      models: normalizedModels.map(({ isDefault, ...entry }) => entry),
      thinkingLevels,
    };
  } catch {
    return operatorVisibleModelsUnavailable("unreachable");
  }
}

export async function assertExplicitModelSupportedByCodexAppServer(args: {
  model: string | null | undefined;
  config?: HubConfig | null;
  engines: ModelEngineResolver;
}): Promise<void> {
  const model = typeof args.model === "string" ? args.model.trim() : "";
  if (!model) return;

  const visibleModels = await loadOperatorVisibleModels({
    config: args.config,
    engines: args.engines,
  });
  if (!visibleModels.ok) {
    throw new Error("Codex app-server model list is unavailable; cannot validate the selected model.");
  }
  if (!visibleModels.models.some((entry) => entry.id === model)) {
    throw new Error(`Selected model is incompatible with current server model list: ${model}`);
  }
}

export function resolveHubModel(config?: HubConfig | null): HubModelResolution {
  const ai = config?.ai;
  if (ai?.provider) {
    const provider = String(ai.provider).trim() || HUB_DEFAULT_PROVIDER;
    const modelId = String(ai.defaultModelId ?? "").trim();
    if (!modelId) {
      return { ok: false, ref: `${provider}/(default)`, reason: "missing_ref", message: "Missing default model id. Run: epoch config" };
    }
    const hasApiKey = hasConfiguredCredentials(config, provider) || Boolean(getEnvApiKey(provider));
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, hasApiKey };
  }

  const refRaw = process.env.EPOCH_MODEL_PRIMARY ?? process.env.EPOCH_MODEL ?? null;
  if (!refRaw) {
    const provider = HUB_DEFAULT_PROVIDER;
    const modelId = HUB_DEFAULT_MODEL_ID;
    const hasApiKey = Boolean(getEnvApiKey(provider));
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, hasApiKey };
  }

  const ref = String(refRaw).trim();
  if (!ref) {
    return { ok: false, ref: null, reason: "missing_ref", message: "Missing model config. Run: epoch config" };
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

function operatorVisibleModelsUnavailable(
  reason: OperatorVisibleModelsFailure["data"]["reason"]
): OperatorVisibleModelsFailure {
  return {
    ok: false,
    code: "MODELS_UNAVAILABLE",
    message: "Codex app-server model list is unavailable.",
    data: {
      source: "codex-app-server",
      retryable: true,
      reason,
    },
  };
}

function normalizeOperatorVisibleModel(
  raw: unknown,
  fallbackProvider: string
): (OperatorVisibleModel & { isDefault: boolean }) | null {
  if (!raw || typeof raw !== "object") return null;
  const record = raw as Record<string, unknown>;
  const id = typeof record.id === "string" ? record.id.trim() : "";
  if (!id) return null;

  const provider = typeof record.provider === "string" && record.provider.trim()
    ? record.provider.trim()
    : fallbackProvider;
  const name = typeof record.displayName === "string" && record.displayName.trim()
    ? record.displayName.trim()
    : typeof record.name === "string" && record.name.trim()
      ? record.name.trim()
      : id;
  const thinkingLevels = normalizeThinkingLevels(record.supportedReasoningEfforts);
  const reasoning = thinkingLevels.length > 0;

  return {
    id,
    provider,
    name,
    reasoning,
    thinkingLevels,
    isDefault: record.isDefault === true,
  };
}

function normalizeThinkingLevels(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const levels = new Set<string>();
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const level = typeof (entry as Record<string, unknown>).reasoningEffort === "string"
      ? (entry as Record<string, unknown>).reasoningEffort.trim()
      : "";
    if (!level || level === "none") continue;
    levels.add(level);
  }
  return [...levels];
}

function collectThinkingLevels(models: Array<{ thinkingLevels: string[] }>): string[] {
  const levels = new Set<string>();
  for (const model of models) {
    for (const level of model.thinkingLevels) {
      levels.add(level);
    }
  }
  return [...levels];
}
