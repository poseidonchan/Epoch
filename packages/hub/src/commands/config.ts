import process from "node:process";
import os from "node:os";
import path from "node:path";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { Writable } from "node:stream";
import { createInterface } from "node:readline/promises";

import { getStateDir, loadOrCreateHubConfig, saveHubConfig, type HubAiAuthConfig, type HubAiConfig } from "../config.js";

type Prompter = {
  close: () => void;
  select: (opts: { message: string; choices: Array<{ label: string; value: string }>; defaultValue?: string }) => Promise<string>;
  input: (opts: { message: string; defaultValue?: string; allowEmpty?: boolean }) => Promise<string>;
  secret: (opts: { message: string; allowEmpty?: boolean }) => Promise<string>;
  confirm: (opts: { message: string; defaultYes?: boolean }) => Promise<boolean>;
};

type PiAiModelInfo = {
  id: string;
  reasoning?: boolean;
};

type PiAiConfigApi = {
  getProviders: () => string[];
  getModels: (provider: string) => PiAiModelInfo[];
  loginOpenAICodex: (opts: {
    originator: string;
    onAuth: (payload: { url: string; instructions?: string }) => void;
    onPrompt: (payload: { message: string }) => Promise<string>;
    onProgress?: (message: string) => void;
  }) => Promise<any>;
};

let piAiConfigApiLoader: Promise<PiAiConfigApi> | null = null;

function loadPiAiConfigApi(): Promise<PiAiConfigApi> {
  if (!piAiConfigApiLoader) {
    piAiConfigApiLoader = Promise.all([
      import("@mariozechner/pi-ai/dist/models.js"),
      import("@mariozechner/pi-ai/dist/utils/oauth/index.js"),
    ]).then(([modelsModule, oauthModule]) => ({
      getProviders: modelsModule.getProviders as any,
      getModels: modelsModule.getModels as any,
      loginOpenAICodex: oauthModule.loginOpenAICodex as any,
    }));
  }
  return piAiConfigApiLoader;
}

function openBrowser(url: string) {
  try {
    const platform = process.platform;
    if (platform === "darwin") {
      spawn("open", [url], { stdio: "ignore", detached: true }).unref();
      return;
    }
    if (platform === "win32") {
      spawn("cmd", ["/c", "start", url], { stdio: "ignore", detached: true }).unref();
      return;
    }
    spawn("xdg-open", [url], { stdio: "ignore", detached: true }).unref();
  } catch {
    // ignore
  }
}

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

  const select = async (opts: { message: string; choices: Array<{ label: string; value: string }>; defaultValue?: string }) => {
    const choices = opts.choices;
    const defaultIdx = opts.defaultValue ? Math.max(0, choices.findIndex((c) => c.value === opts.defaultValue)) : 0;
    process.stdout.write(`${opts.message}\n`);
    choices.forEach((c, idx) => {
      const marker = idx === defaultIdx ? "*" : " ";
      process.stdout.write(`  ${marker} ${idx + 1}) ${c.label}\n`);
    });

    while (true) {
      const raw = (await rl.question(`Enter number [${defaultIdx + 1}]: `)).trim();
      const n = raw ? Number(raw) : defaultIdx + 1;
      if (Number.isFinite(n) && n >= 1 && n <= choices.length) {
        return choices[n - 1]!.value;
      }
      process.stdout.write("Invalid selection.\n");
    }
  };

  return {
    close: () => rl.close(),
    select,
    input,
    secret,
    confirm,
  };
}

function providerApiKeyEnvVar(provider: string): string | null {
  const map: Record<string, string> = {
    openai: "OPENAI_API_KEY",
    anthropic: "ANTHROPIC_API_KEY",
    google: "GEMINI_API_KEY",
    groq: "GROQ_API_KEY",
    cerebras: "CEREBRAS_API_KEY",
    xai: "XAI_API_KEY",
    openrouter: "OPENROUTER_API_KEY",
    "vercel-ai-gateway": "AI_GATEWAY_API_KEY",
    zai: "ZAI_API_KEY",
    mistral: "MISTRAL_API_KEY",
    minimax: "MINIMAX_API_KEY",
    "minimax-cn": "MINIMAX_CN_API_KEY",
    huggingface: "HF_TOKEN",
    opencode: "OPENCODE_API_KEY",
    "kimi-coding": "KIMI_API_KEY",
  };
  return map[provider] ?? null;
}

function providerLabel(provider: string): string {
  switch (provider) {
    case "openai-codex":
      return "openai-codex (ChatGPT OAuth / Codex Subscription)";
    case "openai":
      return "openai (OpenAI API Key)";
    case "anthropic":
      return "anthropic (Anthropic API Key)";
    case "google":
      return "google (Gemini API Key)";
    case "groq":
      return "groq (GROQ_API_KEY)";
    case "mistral":
      return "mistral (MISTRAL_API_KEY)";
    case "openrouter":
      return "openrouter (OPENROUTER_API_KEY)";
    default:
      return provider;
  }
}

function decodeJwtPayload(token: string): Record<string, unknown> | null {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;
    const payload = parts[1] ?? "";
    const decoded = Buffer.from(payload, "base64url").toString("utf8");
    const obj = JSON.parse(decoded);
    return obj && typeof obj === "object" ? (obj as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function jwtExpiresMs(token: string): number | null {
  const payload = decodeJwtPayload(token);
  const exp = payload?.exp;
  if (typeof exp === "number" && Number.isFinite(exp) && exp > 0) return exp * 1000;
  return null;
}

async function importCodexOAuthCredentials(): Promise<HubAiAuthConfig> {
  const authPath = path.join(os.homedir(), ".codex", "auth.json");
  const raw = await readFile(authPath, "utf8");
  const obj: any = JSON.parse(raw);
  const tokens: any = obj?.tokens ?? {};
  const access = typeof tokens.access_token === "string" ? tokens.access_token : "";
  const refresh = typeof tokens.refresh_token === "string" ? tokens.refresh_token : "";
  const accountId = typeof tokens.account_id === "string" ? tokens.account_id : undefined;
  if (!access || !refresh) {
    throw new Error("Codex auth.json is missing access_token/refresh_token. Open Codex once and sign in first.");
  }
  const expires = jwtExpiresMs(access) ?? Date.now() + 45 * 60 * 1000;
  return {
    type: "oauth",
    oauthProviderId: "openai-codex",
    credentials: {
      access,
      refresh,
      expires,
      ...(accountId ? { accountId } : {}),
    },
  };
}

async function loginOpenAICodexOAuth(prompter: Prompter): Promise<HubAiAuthConfig> {
  const piAi = await loadPiAiConfigApi();
  const creds = await piAi.loginOpenAICodex({
    originator: "labos",
    onAuth: ({ url, instructions }) => {
      console.log("\nOpen this URL to authenticate:\n");
      console.log(url + "\n");
      if (instructions) console.log(instructions + "\n");
      openBrowser(url);
    },
    onPrompt: async ({ message }) => {
      return await prompter.input({ message, allowEmpty: false });
    },
    onProgress: (msg) => {
      console.log(msg);
    },
  });

  return {
    type: "oauth",
    oauthProviderId: "openai-codex",
    credentials: creds,
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

export async function configCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
  if (!config) throw new Error("Failed to load hub config");
  const piAi = await loadPiAiConfigApi();

  const prompter = createPrompter();
  try {
    console.log("LabOS Hub configuration wizard\n");
    console.log(`State dir: ${stateDir}`);
    console.log(`Current AI config: ${describeAiConfig(config.ai)}\n`);

    const wants = await prompter.confirm({ message: "Configure model provider + model now?", defaultYes: true });
    if (!wants) {
      console.log("No changes made.");
      return;
    }

    const providers = piAi.getProviders().sort();
    const prioritized = [
      "openai-codex",
      "openai",
      "anthropic",
      "google",
      "groq",
      "mistral",
      "openrouter",
      ...providers.filter((p) => !["openai-codex", "openai", "anthropic", "google", "groq", "mistral", "openrouter"].includes(p)),
    ];

    const provider = await prompter.select({
      message: "Select provider:",
      choices: prioritized.map((p) => ({ label: providerLabel(p), value: p })),
      defaultValue: config.ai?.provider ?? "openai-codex",
    });

    const models = piAi.getModels(provider as any) as Array<any>;
    if (models.length === 0) {
      throw new Error(`No models found for provider: ${provider}`);
    }

    const model = await prompter.select({
      message: `Select default model for ${provider}:`,
      choices: models.map((m) => ({
        label: `${String(m.id)}${m.reasoning ? " (reasoning)" : ""}`,
        value: String(m.id),
      })),
      defaultValue:
        config.ai?.provider === provider
          ? config.ai?.defaultModelId ?? undefined
          : provider === "openai-codex"
            ? "gpt-5.3-codex"
            : undefined,
    });

    let auth: HubAiAuthConfig = { type: "none" };
    if (provider === "openai-codex") {
      const codexPath = path.join(os.homedir(), ".codex", "auth.json");
      const hasCodex = existsSync(codexPath);
      const mode = await prompter.select({
        message: "Authentication for openai-codex:",
        choices: [
          ...(hasCodex
            ? [{ label: "Reuse existing Codex OAuth from ~/.codex/auth.json (Recommended)", value: "reuse" }]
            : []),
          { label: "Browser login (Codex OAuth)", value: "login" },
        ],
        defaultValue: hasCodex ? "reuse" : "login",
      });
      auth = mode === "reuse" ? await importCodexOAuthCredentials() : await loginOpenAICodexOAuth(prompter);
    } else if (provider === "openai") {
      const apiKey = await prompter.secret({ message: "Paste OPENAI_API_KEY:", allowEmpty: false });
      auth = { type: "api_key", provider, apiKey };
    } else {
      const envVar = providerApiKeyEnvVar(provider);
      if (envVar) {
        const apiKey = await prompter.secret({ message: `Paste ${envVar}:`, allowEmpty: false });
        auth = { type: "api_key", provider, apiKey };
      } else {
        console.log(`No wizard auth support for provider "${provider}". Configure credentials via environment variables instead.`);
        auth = { type: "none" };
      }
    }

    const ai: HubAiConfig = { provider, defaultModelId: model, auth };
    config.ai = ai;
    await saveHubConfig({ stateDir, config });

    console.log("\nSaved.");
    console.log(`AI config: ${describeAiConfig(ai)}`);
    console.log("If the Hub is running, restart it to apply changes.");
  } finally {
    prompter.close();
  }
}
