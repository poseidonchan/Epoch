import type { IncomingMessage } from "node:http";

import type { WebSocket } from "ws";

import type { HubConfig } from "../config.js";
import type { DbPool } from "../db/db.js";
import { CodexConnectionState } from "./connection_state.js";
import { CodexEngineRegistry } from "./engine_registry.js";
import { CodexRepository } from "./repository.js";
import type { CodexRuntimeBridge } from "./runtime_bridge.js";
import { CodexRpcRouter } from "./router.js";
import { isJsonRpcNotification, isJsonRpcRequest, isJsonRpcResponse, type JsonRpcRequest, type JsonRpcResponse } from "./types.js";

const OVERLOAD_ERROR_CODE = -32001;
const OVERLOAD_ERROR_MESSAGE = "Server overloaded; retry later.";

export type CodexTransportOptions = {
  ws: WebSocket;
  request: IncomingMessage;
  config: HubConfig;
  stateDir: string;
  pool: DbPool;
  runtimeBridge?: CodexRuntimeBridge;
};

type CodexRuntime = {
  token: string;
  connection: CodexConnectionState;
  repository: CodexRepository;
  engines: CodexEngineRegistry;
  router: CodexRpcRouter;
  ready: Promise<void>;
  activeSocket: WebSocket | null;
};

const runtimesByToken = new Map<string, CodexRuntime>();

export function extractCodexAuthToken(request: IncomingMessage): string | null {
  const host = request.headers.host ?? "localhost";
  const requestUrl = request.url ?? "/codex";

  let parsed: URL;
  try {
    parsed = new URL(requestUrl, `http://${host}`);
  } catch {
    return null;
  }

  const queryToken = parsed.searchParams.get("token");
  if (queryToken && queryToken.trim()) {
    return queryToken.trim();
  }

  const authHeader = request.headers.authorization;
  const rawHeader = Array.isArray(authHeader) ? authHeader[0] : authHeader;
  if (!rawHeader) return null;
  const match = rawHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;
  const token = match[1].trim();
  return token || null;
}

export function attachCodexTransport(options: CodexTransportOptions) {
  const { ws, request, config, stateDir, pool, runtimeBridge } = options;
  const token = extractCodexAuthToken(request) ?? "__labos_default_token__";
  const runtime = getOrCreateRuntime({ token, ws, config, stateDir, pool, runtimeBridge });

  if (runtime.activeSocket && runtime.activeSocket !== ws) {
    try {
      runtime.activeSocket.close(1000, "Replaced by a newer connection");
    } catch {
      // ignore
    }
  }
  runtime.activeSocket = ws;
  runtime.connection.attachWebSocket(ws);

  ws.on("message", (data) => {
    if (!runtime.connection.isAttachedWebSocket(ws)) {
      return;
    }

    const text = data.toString();
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      ws.close(4400, "bad json");
      return;
    }

    const accepted = runtime.connection.ingressQueue.enqueue(async () => {
      await runtime.ready;
      await dispatchInboundMessage(runtime.router, parsed);
    });

    if (!accepted) {
      const maybeRequest = parsed as Partial<JsonRpcRequest>;
      if (maybeRequest && (typeof maybeRequest.id === "string" || typeof maybeRequest.id === "number")) {
        runtime.connection.sendError(maybeRequest.id, OVERLOAD_ERROR_CODE, OVERLOAD_ERROR_MESSAGE);
      }
    }
  });

  ws.on("close", () => {
    if (runtime.connection.isAttachedWebSocket(ws)) {
      runtime.connection.detachWebSocket(ws);
    }
    if (runtime.activeSocket === ws) {
      runtime.activeSocket = null;
    }
  });

  ws.on("error", () => {
    if (runtime.connection.isAttachedWebSocket(ws)) {
      runtime.connection.detachWebSocket(ws);
    }
    if (runtime.activeSocket === ws) {
      runtime.activeSocket = null;
    }
  });
}

export async function closeAllCodexTransports() {
  const runtimes = Array.from(runtimesByToken.values());
  runtimesByToken.clear();

  for (const runtime of runtimes) {
    try {
      runtime.connection.close(new Error("Hub shutdown"));
    } catch {
      // ignore
    }
    try {
      await runtime.router.close();
    } catch {
      // ignore
    }
  }
}

function getOrCreateRuntime(args: {
  token: string;
  ws: WebSocket;
  config: HubConfig;
  stateDir: string;
  pool: DbPool;
  runtimeBridge?: CodexRuntimeBridge;
}): CodexRuntime {
  const existing = runtimesByToken.get(args.token);
  if (existing) {
    return existing;
  }

  const connection = new CodexConnectionState(args.ws, {
    maxIngressQueueDepth: Number(process.env.LABOS_CODEX_MAX_INGRESS_QUEUE ?? "128"),
  });
  const repository = new CodexRepository({ pool: args.pool, stateDir: args.stateDir });
  const engines = new CodexEngineRegistry({ config: args.config, stateDir: args.stateDir });
  const router = new CodexRpcRouter({
    repository,
    engines,
    connection,
    token: args.token,
    runtimeBridge: args.runtimeBridge,
  });
  const ready = repository.clearActiveCodexStateForToken(args.token).catch(() => {});
  const runtime: CodexRuntime = {
    token: args.token,
    connection,
    repository,
    engines,
    router,
    ready,
    activeSocket: null,
  };
  runtimesByToken.set(args.token, runtime);
  return runtime;
}

async function dispatchInboundMessage(router: CodexRpcRouter, message: unknown) {
  if (isJsonRpcRequest(message)) {
    await router.handleRequest(message);
    return;
  }
  if (isJsonRpcNotification(message)) {
    await router.handleNotification(message);
    return;
  }
  if (isJsonRpcResponse(message)) {
    await router.handleResponse(message as JsonRpcResponse);
    return;
  }
}
