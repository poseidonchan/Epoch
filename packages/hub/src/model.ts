import process from "node:process";

// Avoid the heavy package index import, which can stall module initialization.
// Use direct submodule entry points for model/env resolution.
import { getEnvApiKey } from "@mariozechner/pi-ai/dist/env-api-keys.js";
import { getModel, getModels } from "@mariozechner/pi-ai/dist/models.js";

import type { HubConfig } from "./config.js";

const DEFAULT_PROVIDER = "openai-codex";
const DEFAULT_MODEL_ID = "gpt-5.3-codex";

export type HubModelResolution =
  | {
      ok: true;
      ref: string;
      provider: string;
      modelId: string;
      model: any;
      hasApiKey: boolean;
    }
  | {
      ok: false;
      ref: string | null;
      reason: "missing_ref" | "bad_ref" | "unknown_model";
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

export function resolveHubProvider(config?: HubConfig | null): HubProviderResolution {
  const ai = config?.ai;
  if (ai?.provider) {
    const provider = String(ai.provider).trim() || DEFAULT_PROVIDER;
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
    const provider = DEFAULT_PROVIDER;
    const defaultModelId = DEFAULT_MODEL_ID;
    return { provider, defaultModelId, ref: `${provider}/${defaultModelId}`, hasApiKey: Boolean(getEnvApiKey(provider)) };
  }

  const idx = ref.indexOf("/");
  const provider = (idx === -1 ? DEFAULT_PROVIDER : ref.slice(0, idx)).trim();
  const modelId = (idx === -1 ? ref : ref.slice(idx + 1)).trim();
  const hasApiKey = Boolean(getEnvApiKey(provider));
  return { provider: provider || DEFAULT_PROVIDER, defaultModelId: modelId || null, ref, hasApiKey };
}

export function listHubModelsForProvider(provider: string): Array<{ id: string; name: string; reasoning: boolean }> {
  try {
    const models = getModels(provider as any) as Array<any>;
    return models.map((m) => ({ id: String(m.id), name: String(m.name ?? m.id), reasoning: Boolean(m.reasoning) }));
  } catch {
    return [];
  }
}

export function resolveHubModel(config?: HubConfig | null): HubModelResolution {
  const ai = config?.ai;
  if (ai?.provider) {
    const provider = String(ai.provider).trim() || DEFAULT_PROVIDER;
    const modelId = String(ai.defaultModelId ?? "").trim();
    if (!modelId) {
      return { ok: false, ref: `${provider}/(default)`, reason: "missing_ref", message: "Missing default model id. Run: labos-hub config" };
    }

    const hasApiKey = hasConfiguredCredentials(config, provider) || Boolean(getEnvApiKey(provider));

    try {
      const model = getModel(provider as any, modelId as any) as any;
      return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, model, hasApiKey };
    } catch (err: any) {
      return {
        ok: false,
        ref: `${provider}/${modelId}`,
        reason: "unknown_model",
        message: err?.message ?? `Unknown model: ${provider}/${modelId}`,
        provider,
        modelId,
        hasApiKey,
      };
    }
  }

  const refRaw = process.env.LABOS_MODEL_PRIMARY ?? process.env.LABOS_MODEL ?? null;
  if (!refRaw) {
    const provider = DEFAULT_PROVIDER;
    const modelId = DEFAULT_MODEL_ID;
    const hasApiKey = Boolean(getEnvApiKey(provider));
    try {
      const model = getModel(provider as any, modelId as any) as any;
      return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, model, hasApiKey };
    } catch (err: any) {
      return {
        ok: false,
        ref: `${provider}/${modelId}`,
        reason: "unknown_model",
        message: err?.message ?? `Unknown model: ${provider}/${modelId}`,
        provider,
        modelId,
        hasApiKey,
      };
    }
  }

  const ref = String(refRaw).trim();
  if (!ref) {
    return { ok: false, ref: null, reason: "missing_ref", message: "Missing model config. Run: labos-hub config" };
  }

  const idx = ref.indexOf("/");
  const provider = (idx === -1 ? DEFAULT_PROVIDER : ref.slice(0, idx)).trim();
  const modelId = (idx === -1 ? ref : ref.slice(idx + 1)).trim();
  if (!provider || !modelId) {
    return { ok: false, ref, reason: "bad_ref", message: `Invalid model ref: ${ref}` };
  }

  const apiKey = getEnvApiKey(provider);
  const hasApiKey = Boolean(apiKey);

  try {
    const model = getModel(provider as any, modelId as any) as any;
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, model, hasApiKey };
  } catch (err: any) {
    return {
      ok: false,
      ref,
      reason: "unknown_model",
      message: err?.message ?? `Unknown model: ${ref}`,
      provider,
      modelId,
      hasApiKey,
    };
  }
}

export function resolveHubModelForRun(config: HubConfig | null, opts: { modelIdOverride?: string | null }): HubModelResolution {
  const base = resolveHubProvider(config);
  if (!base.defaultModelId && !opts.modelIdOverride) {
    return { ok: false, ref: base.ref, reason: "missing_ref", message: "Missing model config. Run: labos-hub config" };
  }
  const modelId = (opts.modelIdOverride ?? base.defaultModelId ?? "").trim();
  if (!modelId) {
    return { ok: false, ref: base.ref, reason: "missing_ref", message: "Missing model id." };
  }
  const provider = base.provider;
  const hasApiKey = base.hasApiKey || hasConfiguredCredentials(config, provider);
  try {
    const model = getModel(provider as any, modelId as any) as any;
    return { ok: true, ref: `${provider}/${modelId}`, provider, modelId, model, hasApiKey };
  } catch (err: any) {
    return {
      ok: false,
      ref: base.ref ?? `${provider}/${modelId}`,
      reason: "unknown_model",
      message: err?.message ?? `Unknown model: ${provider}/${modelId}`,
      provider,
      modelId,
      hasApiKey,
    };
  }
}
