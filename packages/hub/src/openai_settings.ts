import type { HubConfig } from "./config.js";
import { loadOrCreateHubConfig } from "./config.js";

export type OpenAISettingsStatus = {
  configured: boolean;
  updatedAt: string | null;
  source: string | null;
  ocrModel: string;
};

export const DEFAULT_OPENAI_PDF_OCR_MODEL = "gpt-5.2";

export function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function resolveOpenAIApiKeyFromConfig(config: HubConfig | null | undefined): string | undefined {
  const providerKey = normalizeOptionalString(config?.providerApiKeys?.openai);
  if (providerKey) return providerKey;
  const auth = config?.ai?.auth;
  if (auth?.type === "api_key" && auth.provider === "openai") {
    return normalizeOptionalString(auth.apiKey) ?? undefined;
  }
  return undefined;
}

export function resolveOpenAIOcrModelFromConfig(config: HubConfig | null | undefined): string | undefined {
  const configuredModel = normalizeOptionalString(config?.openaiSettings?.ocrModel);
  if (configuredModel) return configuredModel;
  return undefined;
}

export function resolveEffectiveOpenAIOcrModel(config: HubConfig | null | undefined): string {
  const configuredModel = resolveOpenAIOcrModelFromConfig(config);
  if (configuredModel) return configuredModel;
  const envModel = normalizeOptionalString(process.env.EPOCH_PDF_OCR_MODEL);
  if (envModel) return envModel;
  return DEFAULT_OPENAI_PDF_OCR_MODEL;
}

export async function loadOpenAIApiKeyFromStateDir(stateDir: string): Promise<string | undefined> {
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false }).catch(() => null);
  return resolveOpenAIApiKeyFromConfig(config);
}

export function readOpenAISettingsStatus(config: HubConfig | null | undefined): OpenAISettingsStatus {
  const configured = Boolean(resolveOpenAIApiKeyFromConfig(config));
  const meta = config?.providerApiKeyMetadata?.openai;
  return {
    configured,
    updatedAt: normalizeOptionalString(meta?.updatedAt),
    source: normalizeOptionalString(meta?.source),
    ocrModel: resolveEffectiveOpenAIOcrModel(config),
  };
}
