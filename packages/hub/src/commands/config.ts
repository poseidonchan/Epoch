import {
  getStateDir,
  loadOrCreateHubConfig,
  saveHubConfig,
  type HubAiAuthConfig,
  type HubAiConfig,
  type HubConfig,
} from "../config.js";
import { HUB_DEFAULT_MODEL_ID, HUB_DEFAULT_PROVIDER, hubDefaultModelRef } from "../model.js";
import { resolvePairingWSURL } from "./pair_qr.js";
import { createWizardPrompter, createWizardUI, type WizardPrompter, type WizardUI } from "./wizard_ui.js";

function describeAiConfig(ai: HubAiConfig | undefined): string {
  if (!ai) return "not configured";
  const model = ai.defaultModelId ? `${ai.provider}/${ai.defaultModelId}` : `${ai.provider}/(default)`;
  const auth =
    ai.auth.type === "none"
      ? "none"
      : ai.auth.type === "api_key"
        ? "api key"
        : `oauth:${ai.auth.oauthProviderId}`;
  return `${model} (${auth})`;
}

function preserveCodexOAuthAuth(ai: HubAiConfig | undefined): HubAiAuthConfig {
  const auth = ai?.auth;
  if (auth?.type === "oauth" && auth.oauthProviderId === "openai-codex") {
    return auth;
  }
  return { type: "none" };
}

type ConfigCommandOptions = {
  ui?: WizardUI;
  prompter?: WizardPrompter;
};

export async function configCommand(_argv: string[], options: ConfigCommandOptions = {}) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
  if (!config) throw new Error("Failed to load hub config");

  const ui = options.ui ?? createWizardUI();
  const prompter = options.prompter ?? createWizardPrompter(ui);
  const ownsPrompter = !options.prompter;

  try {
    await runConfigWizard({ stateDir, config, ui, prompter });
  } finally {
    if (ownsPrompter) prompter.close();
  }
}

async function runConfigWizard(args: {
  stateDir: string;
  config: HubConfig;
  ui: WizardUI;
  prompter: WizardPrompter;
}) {
  const { stateDir, config, ui, prompter } = args;

  const previousAi = describeAiConfig(config.ai);
  const previousEmbeddingState = config.providerApiKeys?.openai ? "configured" : "not configured";
  const previousDisplayName = config.displayName ?? "not configured";
  const previousWorkspaceRoot = config.workspaceRoot ?? "not configured";
  const previousPushRelayEnabled = config.pushEnabled === true ? "enabled" : "disabled";
  const previousPushRelayUrl = config.pushRelayUrl ?? "not configured";
  const previousPushRelaySecret = config.pushRelaySharedSecret ? "configured" : "not configured";
  const pairingWS = await resolvePairingWSURL({ env: process.env, config, defaultPort: 8787 });
  const previousPublicWsUrl = pairingWS.wsURL;
  const previousPublicWsUrlSource = pairingWS.source;

  ui.banner("Epoch Server Configuration", "Guided setup for direct pairing, local runtime defaults, and embedding key");
  ui.step(1, 6, "Load existing settings", "ok");
  ui.keyValue("State dir", stateDir);
  ui.keyValue("Display name", previousDisplayName);
  ui.keyValue("Current AI config", previousAi);
  ui.keyValue("Default workspace root", previousWorkspaceRoot);
  ui.keyValue("Pairing WS URL", previousPublicWsUrl);
  ui.keyValue("Pairing source", previousPublicWsUrlSource);
  ui.keyValue("Push relay", previousPushRelayEnabled);
  ui.keyValue("Push relay URL", previousPushRelayUrl);
  ui.keyValue("Push relay secret", previousPushRelaySecret);
  ui.keyValue("Current embedding key (openai)", previousEmbeddingState);
  ui.keyValue("Target codex model", hubDefaultModelRef());
  ui.line();

  const wants = await prompter.confirm({
    message: "Apply direct-connect defaults and configure OPENAI_API_KEY for file embeddings?",
    defaultYes: true,
  });
  if (!wants) {
    ui.step(2, 6, "No changes requested", "warn");
    return;
  }
  ui.step(2, 6, "Collect direct-connect settings", "ok");

  const displayName = await prompter.input({
    message: "Display name shown in EpochApp:",
    defaultValue: config.displayName ?? "",
  });
  const workspaceRoot = await prompter.input({
    message: "Default workspace root for new projects:",
    defaultValue: config.workspaceRoot ?? "",
  });
  const publicWsUrl = await prompter.input({
    message: "Pairing WS URL for phone pairing (leave blank to keep auto-detect/loopback):",
    defaultValue: config.publicWsUrl ?? (pairingWS.source === "tailscale" ? pairingWS.wsURL : ""),
    allowEmpty: true,
  });

  ui.step(3, 6, "Collect push relay settings", "ok");
  const pushEnabled = await prompter.confirm({
    message: "Enable central Push Relay for background Codex keepalive?",
    defaultYes: config.pushEnabled === true,
  });
  const pushRelayUrl = pushEnabled
    ? await prompter.input({
        message: "Push Relay base URL:",
        defaultValue: config.pushRelayUrl ?? "",
      })
    : "";
  const pushRelaySharedSecretInput = pushEnabled
    ? await prompter.secret({
        message: config.pushRelaySharedSecret
          ? "Push Relay shared secret (leave blank to keep current):"
          : "Push Relay shared secret:",
        allowEmpty: Boolean(config.pushRelaySharedSecret),
      })
    : "";

  ui.step(4, 6, "Collect credentials", "ok");

  const existingEmbeddingKey = config.providerApiKeys?.openai?.trim() ?? "";
  const openAiApiKey = await prompter.secret({
    message: existingEmbeddingKey
      ? "Paste OPENAI_API_KEY for file embeddings (leave blank to keep current):"
      : "Paste OPENAI_API_KEY for file embeddings (optional, leave blank to skip):",
    allowEmpty: true,
  });
  const normalizedEmbeddingKey = openAiApiKey.trim() || existingEmbeddingKey;
  const normalizedPushRelaySecret = pushEnabled
    ? pushRelaySharedSecretInput.trim() || config.pushRelaySharedSecret?.trim() || ""
    : "";

  ui.step(5, 6, "Apply direct-connect defaults", "ok");
  config.ai = {
    provider: HUB_DEFAULT_PROVIDER,
    defaultModelId: HUB_DEFAULT_MODEL_ID,
    auth: preserveCodexOAuthAuth(config.ai),
  };
  config.displayName = displayName.trim();
  config.workspaceRoot = workspaceRoot.trim();
  config.publicWsUrl = publicWsUrl.trim() || null;
  config.pushEnabled = pushEnabled;
  config.pushRelayUrl = pushEnabled ? pushRelayUrl.trim() || null : null;
  config.pushRelaySharedSecret = pushEnabled ? normalizedPushRelaySecret || null : null;

  const providerApiKeys = { ...(config.providerApiKeys ?? {}) };
  if (normalizedEmbeddingKey) {
    providerApiKeys.openai = normalizedEmbeddingKey;
  } else {
    delete providerApiKeys.openai;
  }

  if (Object.keys(providerApiKeys).length === 0) {
    delete config.providerApiKeys;
  } else {
    config.providerApiKeys = providerApiKeys;
  }

  await saveHubConfig({ stateDir, config });
  ui.step(6, 6, "Persist settings", "ok");
  ui.success("Epoch server configuration saved.");
  ui.summary("Configuration summary", [
    { key: "Display name", before: previousDisplayName, after: config.displayName ?? "not configured" },
    { key: "Default workspace root", before: previousWorkspaceRoot, after: config.workspaceRoot ?? "not configured" },
    { key: "Pairing WS URL", before: previousPublicWsUrl, after: config.publicWsUrl ?? "auto-detect / loopback" },
    { key: "Push Relay", before: previousPushRelayEnabled, after: config.pushEnabled === true ? "enabled" : "disabled" },
    { key: "Push Relay URL", before: previousPushRelayUrl, after: config.pushRelayUrl ?? "not configured" },
    {
      key: "Push Relay secret",
      before: previousPushRelaySecret,
      after: config.pushRelaySharedSecret ? "configured" : "not configured",
    },
    { key: "AI backend", before: previousAi, after: describeAiConfig(config.ai) },
    { key: "AI target model", after: hubDefaultModelRef() },
    {
      key: "Embedding key (openai)",
      before: previousEmbeddingState,
      after: normalizedEmbeddingKey ? "configured" : "not configured (uploads indexing will fail)",
    },
  ]);

  ui.note("If Epoch is running, restart it to apply changes.");
}
