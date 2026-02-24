import path from "node:path";
import { readFile } from "node:fs/promises";
import { v4 as uuidv4 } from "uuid";

import { getEnvApiKey } from "@mariozechner/pi-ai/dist/env-api-keys.js";

import type { HubConfig } from "../../config.js";
import { resolveHubModelForRun } from "../../model.js";
import type { Turn, UserInput } from "../types.js";
import { nowUnixSeconds } from "../types.js";
import { AsyncPushQueue, flattenUserInputToText, type CodexEngineSession, type EngineStartTurnArgs, type EngineStartTurnResult, type EngineStreamEvent } from "./types.js";

type PiContext = any;
type PiModel = any;
type SimpleStreamOptions = {
  apiKey?: string;
};

type TextContent = {
  type: "text";
  text: string;
};

type ImageContent = {
  type: "image";
  mimeType: string;
  data: string;
};

type OAuthProvider = {
  refreshToken: (credentials: any) => Promise<any>;
  getApiKey: (credentials: any) => string;
};

let streamSimpleLoader: Promise<(model: any, context: any, options?: any) => AsyncIterable<any>> | null = null;
let oauthProviderLoader: Promise<(id: string) => OAuthProvider | undefined> | null = null;

function loadStreamSimple() {
  if (!streamSimpleLoader) {
    streamSimpleLoader = import("@mariozechner/pi-ai/dist/stream.js").then((mod) => mod.streamSimple as any);
  }
  return streamSimpleLoader;
}

function loadOAuthProvider() {
  if (!oauthProviderLoader) {
    oauthProviderLoader = import("@mariozechner/pi-ai/dist/utils/oauth/index.js").then((mod) => mod.getOAuthProvider as any);
  }
  return oauthProviderLoader;
}

export class PiAgentEngineAdapter implements CodexEngineSession {
  readonly name = "pi";

  private readonly config: HubConfig | null;
  private readonly interruptedTurns = new Set<string>();

  constructor(opts: { config: HubConfig | null }) {
    this.config = opts.config;
  }

  async startTurn(args: EngineStartTurnArgs): Promise<EngineStartTurnResult> {
    const queue = new AsyncPushQueue<EngineStreamEvent>();

    const turn: Turn = {
      id: args.turnId,
      items: [],
      status: "inProgress",
      error: null,
    };

    void this.runTurn(args, queue);

    return { turn, events: queue };
  }

  async interruptTurn(args: { threadId: string; turnId: string }): Promise<void> {
    this.interruptedTurns.add(args.turnId);
  }

  async close(): Promise<void> {
    this.interruptedTurns.clear();
  }

  private async runTurn(args: EngineStartTurnArgs, queue: AsyncPushQueue<EngineStreamEvent>) {
    const agentMessageItemId = `item_${uuidv4()}`;
    let fullText = "";

    queue.push({
      type: "notification",
      method: "item/started",
      params: {
        threadId: args.threadId,
        turnId: args.turnId,
        item: {
          type: "agentMessage",
          id: agentMessageItemId,
          text: "",
        },
      },
    });

    try {
      const userContent = await buildPiUserContentFromCodexInput(args.input);
      const resolution = resolveHubModelForRun(this.config, { modelIdOverride: args.model });

      if (!resolution.ok) {
        fullText = `Model resolution error: ${resolution.message}`;
      } else {
        const context: PiContext = {
          systemPrompt: "You are LabOS, a concise and helpful assistant.",
          messages: [
            {
              role: "user",
              content: piUserMessageContent(userContent),
              timestamp: Date.now(),
            },
          ],
        } as PiContext;

        const apiKey = await resolveApiKeyForProvider(this.config, resolution.provider);
        const streamOptions: SimpleStreamOptions = {
          ...(apiKey ? { apiKey } : {}),
        };

        const streamSimple = await loadStreamSimple();
        const stream = streamSimple(resolution.model as PiModel, context as any, streamOptions);
        for await (const event of stream as AsyncIterable<any>) {
          if (this.interruptedTurns.has(args.turnId)) {
            break;
          }

          if (event?.type === "text_delta") {
            const delta = String(event.delta ?? "");
            if (!delta) continue;
            fullText += delta;
            queue.push({
              type: "notification",
              method: "item/agentMessage/delta",
              params: {
                threadId: args.threadId,
                turnId: args.turnId,
                itemId: agentMessageItemId,
                delta,
              },
            });
            continue;
          }

          if (event?.type === "error") {
            const message = String(event.error?.errorMessage ?? event.error?.message ?? "unknown model error");
            throw new Error(message);
          }
        }

        if (this.interruptedTurns.has(args.turnId)) {
          if (!fullText.trim()) {
            fullText = "Turn interrupted.";
          }
        }
      }

      if (!fullText.trim()) {
        fullText = "No assistant response was produced.";
      }

      queue.push({
        type: "notification",
        method: "item/completed",
        params: {
          threadId: args.threadId,
          turnId: args.turnId,
          item: {
            type: "agentMessage",
            id: agentMessageItemId,
            text: fullText,
          },
        },
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      queue.push({
        type: "notification",
        method: "item/completed",
        params: {
          threadId: args.threadId,
          turnId: args.turnId,
          item: {
            type: "agentMessage",
            id: agentMessageItemId,
            text: `Agent error: ${message}`,
          },
        },
      });
    } finally {
      const wasInterrupted = this.interruptedTurns.has(args.turnId);
      this.interruptedTurns.delete(args.turnId);

      queue.push({
        type: "notification",
        method: "turn/completed",
        params: {
          threadId: args.threadId,
          turn: {
            id: args.turnId,
            items: [],
            status: wasInterrupted ? "interrupted" : "completed",
            error: null,
          },
          completedAt: nowUnixSeconds(),
        },
      });
      queue.finish();
    }
  }
}

export type PiUserContentPart = TextContent | ImageContent;

export async function buildPiUserContentFromCodexInput(input: UserInput[]): Promise<PiUserContentPart[]> {
  const content: PiUserContentPart[] = [];

  for (const part of input) {
    if (part.type === "text") {
      const text = String(part.text ?? "");
      if (text.trim()) {
        content.push({ type: "text", text });
      }
      continue;
    }

    if (part.type === "localImage") {
      const image = await loadImageContentFromLocalPath(part.path);
      if (image) {
        content.push(image);
      }
      continue;
    }

    if (part.type === "image") {
      const image = await loadImageContentFromImageUrl(part.url);
      if (image) {
        content.push(image);
      }
      continue;
    }

    if (part.type === "skill" && String(part.name ?? "").trim()) {
      content.push({ type: "text", text: `[skill:${part.name}]` });
      continue;
    }

    if (part.type === "mention" && String(part.name ?? "").trim()) {
      content.push({ type: "text", text: `[mention:${part.name}]` });
      continue;
    }
  }

  if (content.length > 0) {
    if (!content.some((part) => part.type === "text")) {
      content.unshift({ type: "text", text: "Analyze the attached image(s)." });
    }
    return content;
  }

  const fallback = flattenUserInputToText(input);
  if (fallback) {
    return [{ type: "text", text: fallback }];
  }

  return [{ type: "text", text: "" }];
}

function piUserMessageContent(content: PiUserContentPart[]): string | PiUserContentPart[] {
  if (content.length === 1 && content[0]?.type === "text") {
    return content[0].text;
  }
  return content;
}

async function loadImageContentFromImageUrl(url: string): Promise<ImageContent | null> {
  const raw = String(url ?? "").trim();
  if (!raw) return null;

  const dataUrl = parseDataImageUrl(raw);
  if (dataUrl) return dataUrl;

  if (raw.startsWith("file://")) {
    try {
      const parsed = new URL(raw);
      return await loadImageContentFromLocalPath(parsed.pathname);
    } catch {
      return null;
    }
  }

  return null;
}

function parseDataImageUrl(raw: string): ImageContent | null {
  const match = /^data:(image\/[a-z0-9.+-]+);base64,([a-z0-9+/=]+)$/i.exec(raw);
  if (!match) return null;
  const mimeType = String(match[1] ?? "").toLowerCase();
  const data = String(match[2] ?? "").replace(/\s+/g, "");
  if (!mimeType.startsWith("image/") || !data) return null;
  return {
    type: "image",
    mimeType,
    data,
  };
}

async function loadImageContentFromLocalPath(filePath: string): Promise<ImageContent | null> {
  const normalizedPath = String(filePath ?? "").trim();
  if (!normalizedPath) return null;
  try {
    const bytes = await readFile(normalizedPath);
    if (!bytes.length) return null;
    const data = bytes.toString("base64");
    if (!data) return null;
    return {
      type: "image",
      mimeType: inferImageMimeTypeFromPath(normalizedPath),
      data,
    };
  } catch {
    return null;
  }
}

function inferImageMimeTypeFromPath(filePath: string): string {
  const ext = path.extname(String(filePath ?? "").toLowerCase());
  switch (ext) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".bmp":
      return "image/bmp";
    case ".heic":
      return "image/heic";
    case ".heif":
      return "image/heif";
    case ".tif":
    case ".tiff":
      return "image/tiff";
    default:
      return "image/jpeg";
  }
}

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

async function resolveApiKeyForProvider(config: HubConfig | null, provider: string): Promise<string | undefined> {
  const normalizedProvider = String(provider ?? "").trim();
  if (!normalizedProvider) return undefined;

  const auth = config?.ai?.auth;
  if (auth?.type === "api_key") {
    if (auth.provider === normalizedProvider && auth.apiKey) {
      return auth.apiKey;
    }
    return getEnvApiKey(normalizedProvider) ?? undefined;
  }

  if (auth?.type === "oauth") {
    const mappedProvider = oauthProviderToModelProvider(auth.oauthProviderId);
    if (mappedProvider === normalizedProvider) {
      const getOAuthProvider = await loadOAuthProvider();
      const oauth = getOAuthProvider(auth.oauthProviderId);
      if (!oauth) return getEnvApiKey(normalizedProvider) ?? undefined;

      const credentials: any = auth.credentials;
      if (
        !credentials ||
        typeof credentials.refresh !== "string" ||
        typeof credentials.access !== "string" ||
        typeof credentials.expires !== "number"
      ) {
        return getEnvApiKey(normalizedProvider) ?? undefined;
      }

      try {
        if (Date.now() >= credentials.expires - 60_000) {
          const refreshed = await oauth.refreshToken(credentials);
          auth.credentials = refreshed as any;
        }
        return oauth.getApiKey(auth.credentials as any);
      } catch {
        return getEnvApiKey(normalizedProvider) ?? undefined;
      }
    }
  }

  return getEnvApiKey(normalizedProvider) ?? undefined;
}
