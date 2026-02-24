import process from "node:process";
import { Writable } from "node:stream";
import { createInterface } from "node:readline/promises";

import { getStateDir, loadOrCreateHubConfig, saveHubConfig, type HubAiAuthConfig, type HubAiConfig } from "../config.js";

type Prompter = {
  close: () => void;
  input: (opts: { message: string; defaultValue?: string; allowEmpty?: boolean }) => Promise<string>;
  secret: (opts: { message: string; allowEmpty?: boolean }) => Promise<string>;
  confirm: (opts: { message: string; defaultYes?: boolean }) => Promise<boolean>;
};

function createPrompter(): Prompter {
  let muted = false;
  const output = new Writable({
    write(chunk, encoding, callback) {
      if (!muted) {
        process.stdout.write(chunk, encoding as any);
      }
      callback();
    },
  });
  const rl = createInterface({ input: process.stdin, output, terminal: true });

  const input = async (opts: { message: string; defaultValue?: string; allowEmpty?: boolean }) => {
    const prompt = opts.defaultValue ? `${opts.message} [${opts.defaultValue}] ` : `${opts.message} `;
    while (true) {
      const raw = (await rl.question(prompt)).trimEnd();
      const value = raw.trim();
      if (value) return value;
      if (opts.defaultValue != null) return String(opts.defaultValue);
      if (opts.allowEmpty) return "";
      process.stdout.write("Value required.\n");
    }
  };

  const secret = async (opts: { message: string; allowEmpty?: boolean }) => {
    while (true) {
      process.stdout.write(`${opts.message} `);
      muted = true;
      const raw = (await rl.question("")).trimEnd();
      muted = false;
      process.stdout.write("\n");
      const value = raw.trim();
      if (value) return value;
      if (opts.allowEmpty) return "";
      process.stdout.write("Value required.\n");
    }
  };

  const confirm = async (opts: { message: string; defaultYes?: boolean }) => {
    const suffix = opts.defaultYes === false ? "[y/N]" : "[Y/n]";
    const raw = (await rl.question(`${opts.message} ${suffix} `)).trim().toLowerCase();
    if (!raw) return opts.defaultYes !== false;
    return raw === "y" || raw === "yes";
  };

  return {
    close: () => rl.close(),
    input,
    secret,
    confirm,
  };
}

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

export async function configCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
  if (!config) throw new Error("Failed to load hub config");

  const prompter = createPrompter();
  try {
    console.log("LabOS Hub configuration wizard\n");
    console.log(`State dir: ${stateDir}`);
    console.log(`Current AI config: ${describeAiConfig(config.ai)}`);
    console.log(`Current embedding key (openai): ${config.providerApiKeys?.openai ? "configured" : "not configured"}\n`);

    const wants = await prompter.confirm({
      message: "Apply codex backend defaults and configure OPENAI_API_KEY for file embeddings?",
      defaultYes: true,
    });
    if (!wants) {
      console.log("No changes made.");
      return;
    }

    const existingEmbeddingKey = config.providerApiKeys?.openai?.trim() ?? "";
    const openAiApiKey = await prompter.secret({
      message: existingEmbeddingKey
        ? "Paste OPENAI_API_KEY for file embeddings (leave blank to keep current):"
        : "Paste OPENAI_API_KEY for file embeddings (optional, leave blank to skip):",
      allowEmpty: true,
    });
    const normalizedEmbeddingKey = openAiApiKey.trim() || existingEmbeddingKey;

    config.ai = {
      provider: "openai-codex",
      defaultModelId: "gpt-5.3-codex",
      auth: preserveCodexOAuthAuth(config.ai),
    };

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

    console.log("\nSaved.");
    console.log("Codex backend: openai-codex/gpt-5.3-codex");
    console.log(`Embedding key (openai): ${normalizedEmbeddingKey ? "configured" : "not configured (uploads indexing will fail)"}`);
    console.log("If the Hub is running, restart it to apply changes.");
  } finally {
    prompter.close();
  }
}
