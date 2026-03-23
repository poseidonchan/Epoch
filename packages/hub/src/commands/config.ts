import {
  getStateDir,
  loadOrCreateHubConfig,
  saveHubConfig,
  type HubAiAuthConfig,
  type HubAiConfig,
  type HubConfig,
} from "../config.js";
import { HUB_DEFAULT_MODEL_ID, HUB_DEFAULT_PROVIDER, hubDefaultModelRef } from "../model.js";
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
  const previousWorkspaceRoot = config.workspaceRoot ?? "not configured";
  const previousPublicWsUrl = config.publicWsUrl ?? "not configured";

  ui.banner("Epoch Direct Connect Configuration", "Guided setup for local runtime defaults, pairing URL, and embedding key");
  ui.step(1, 5, "Load existing settings", "ok");
  ui.keyValue("State dir", stateDir);
  ui.keyValue("Current AI config", previousAi);
  ui.keyValue("Default workspace root", previousWorkspaceRoot);
  ui.keyValue("Public WS URL", previousPublicWsUrl);
  ui.keyValue("Current embedding key (openai)", previousEmbeddingState);
  ui.keyValue("Target codex model", hubDefaultModelRef());
  ui.line();

  const wants = await prompter.confirm({
    message: "Apply direct-connect defaults and configure OPENAI_API_KEY for file embeddings?",
    defaultYes: true,
  });
  if (!wants) {
    ui.step(2, 5, "No changes requested", "warn");
    return;
  }
  ui.step(2, 5, "Collect direct-connect settings", "ok");

  const workspaceRoot = await prompter.input({
    message: "Default workspace root for new projects:",
    defaultValue: config.workspaceRoot ?? "",
  });
  const publicWsUrl = await prompter.input({
    message: "Public WS URL for phone pairing (optional, leave blank to keep loopback fallback):",
    defaultValue: config.publicWsUrl ?? "",
    allowEmpty: true,
  });

  ui.step(3, 5, "Collect credentials", "ok");

  const existingEmbeddingKey = config.providerApiKeys?.openai?.trim() ?? "";
  const openAiApiKey = await prompter.secret({
    message: existingEmbeddingKey
      ? "Paste OPENAI_API_KEY for file embeddings (leave blank to keep current):"
      : "Paste OPENAI_API_KEY for file embeddings (optional, leave blank to skip):",
    allowEmpty: true,
  });
  const normalizedEmbeddingKey = openAiApiKey.trim() || existingEmbeddingKey;

  ui.step(4, 5, "Apply direct-connect defaults", "ok");
  config.ai = {
    provider: HUB_DEFAULT_PROVIDER,
    defaultModelId: HUB_DEFAULT_MODEL_ID,
    auth: preserveCodexOAuthAuth(config.ai),
  };
  config.workspaceRoot = workspaceRoot.trim();
  config.publicWsUrl = publicWsUrl.trim() || null;

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
  ui.step(5, 5, "Persist settings", "ok");
  ui.success("Hub configuration saved.");
  ui.summary("Configuration summary", [
    { key: "Default workspace root", before: previousWorkspaceRoot, after: config.workspaceRoot ?? "not configured" },
    { key: "Public WS URL", before: previousPublicWsUrl, after: config.publicWsUrl ?? "not configured" },
    { key: "AI backend", before: previousAi, after: describeAiConfig(config.ai) },
    { key: "AI target model", after: hubDefaultModelRef() },
    {
      key: "Embedding key (openai)",
      before: previousEmbeddingState,
      after: normalizedEmbeddingKey ? "configured" : "not configured (uploads indexing will fail)",
    },
  ]);

  ui.note("If the Hub is running, restart it to apply changes.");
}
