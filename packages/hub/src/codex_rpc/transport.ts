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
import type { CodexEngineSession } from "./engines/types.js";

const OVERLOAD_ERROR_CODE = -32001;
const OVERLOAD_ERROR_MESSAGE = "Server overloaded; retry later.";
const DEFAULT_IDLE_TTL_MS = 15 * 60 * 1000;

export type CodexTransportOptions = {
  ws: WebSocket;
  request: IncomingMessage;
  config: HubConfig;
  stateDir: string;
  pool: DbPool;
  runtimeBridge?: CodexRuntimeBridge;
  createEngines?: (args: { config: HubConfig; stateDir: string }) => CodexEnginesLike;
};

type CodexEnginesLike = {
  getEngine(name: string | null | undefined): Promise<CodexEngineSession>;
  activeTurnCount(): number;
  close(): Promise<void>;
};

type CodexRuntime = {
  token: string;
  connection: CodexConnectionState;
  repository: CodexRepository;
  engines: CodexEnginesLike;
  router: CodexRpcRouter;
  ready: Promise<void>;
  activeSocket: WebSocket | null;
  idleTimer: NodeJS.Timeout | null;
  idleSinceMs: number | null;
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
  const { ws, request, config, stateDir, pool, runtimeBridge, createEngines } = options;
  const token = extractCodexAuthToken(request) ?? "__epoch_default_token__";
  const runtime = getOrCreateRuntime({ token, ws, config, stateDir, pool, runtimeBridge, createEngines });
  const previousSocket = runtime.activeSocket;
  cancelRuntimeIdleTimer(runtime);
  runtime.idleSinceMs = null;

  runtime.activeSocket = ws;
  runtime.connection.attachWebSocket(ws);

  if (previousSocket && previousSocket !== ws) {
    try {
      previousSocket.close(1000, "Replaced by a newer connection");
    } catch {
      // ignore
    }
  }

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
    handleSocketDetached(runtime, ws);
  });

  ws.on("error", () => {
    handleSocketDetached(runtime, ws);
  });
}

export async function closeAllCodexTransports() {
  const runtimes = Array.from(runtimesByToken.values());
  runtimesByToken.clear();

  for (const runtime of runtimes) {
    await closeRuntime(runtime, new Error("Hub shutdown"));
  }
}

export function runtimeCountForTesting(): number {
  return runtimesByToken.size;
}

function getOrCreateRuntime(args: {
  token: string;
  ws: WebSocket;
  config: HubConfig;
  stateDir: string;
  pool: DbPool;
  runtimeBridge?: CodexRuntimeBridge;
  createEngines?: (args: { config: HubConfig; stateDir: string }) => CodexEnginesLike;
}): CodexRuntime {
  const existing = runtimesByToken.get(args.token);
  if (existing) {
    return existing;
  }

  const connection = new CodexConnectionState(args.ws, {
    maxIngressQueueDepth: Number(process.env.EPOCH_CODEX_MAX_INGRESS_QUEUE ?? "128"),
  });
  const repository = new CodexRepository({ pool: args.pool, stateDir: args.stateDir });
  const engines = args.createEngines?.({ config: args.config, stateDir: args.stateDir }) ?? new CodexEngineRegistry({ config: args.config, stateDir: args.stateDir });
  const router = new CodexRpcRouter({
    repository,
    engines: engines as CodexEngineRegistry,
    connection,
    token: args.token,
    serverId: args.config.serverId,
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
    idleTimer: null,
    idleSinceMs: null,
  };
  runtimesByToken.set(args.token, runtime);
  return runtime;
}

function handleSocketDetached(runtime: CodexRuntime, ws: WebSocket) {
  if (runtime.connection.isAttachedWebSocket(ws)) {
    runtime.connection.detachWebSocket(ws);
  }
  if (runtime.activeSocket === ws) {
    runtime.activeSocket = null;
  }
  if (!runtime.activeSocket) {
    if (runtime.engines.activeTurnCount() > 0) {
      runtime.idleSinceMs = null;
      scheduleRuntimeIdleEvaluation(runtime, Math.min(1_000, resolveIdleTtlMs()));
      return;
    }

    runtime.idleSinceMs = Date.now();
    scheduleRuntimeIdleEvaluation(runtime, resolveIdleTtlMs());
  }
}

function scheduleRuntimeIdleEvaluation(runtime: CodexRuntime, delayMs?: number) {
  cancelRuntimeIdleTimer(runtime);
  const ttlMs = resolveIdleTtlMs();
  const nextDelayMs = Math.max(1, Math.floor(delayMs ?? ttlMs));
  runtime.idleTimer = setTimeout(() => {
    void evaluateRuntimeIdle(runtime);
  }, nextDelayMs);
  runtime.idleTimer.unref?.();
}

async function evaluateRuntimeIdle(runtime: CodexRuntime) {
  runtime.idleTimer = null;
  if (runtime.activeSocket) {
    runtime.idleSinceMs = null;
    return;
  }

  const activeTurnCount = runtime.engines.activeTurnCount();
  if (activeTurnCount > 0) {
    runtime.idleSinceMs = null;
    scheduleRuntimeIdleEvaluation(runtime, Math.min(1_000, resolveIdleTtlMs()));
    return;
  }

  const now = Date.now();
  const idleSinceMs = runtime.idleSinceMs ?? now;
  runtime.idleSinceMs = idleSinceMs;
  const remainingMs = idleSinceMs + resolveIdleTtlMs() - now;
  if (remainingMs > 0) {
    scheduleRuntimeIdleEvaluation(runtime, remainingMs);
    return;
  }

  if (runtimesByToken.get(runtime.token) === runtime) {
    runtimesByToken.delete(runtime.token);
  }
  await closeRuntime(runtime, new Error("Codex runtime idle timeout"));
}

async function closeRuntime(runtime: CodexRuntime, err: Error) {
  cancelRuntimeIdleTimer(runtime);
  try {
    runtime.connection.close(err);
  } catch {
    // ignore
  }
  try {
    await runtime.router.close();
  } catch {
    // ignore
  }
}

function cancelRuntimeIdleTimer(runtime: CodexRuntime) {
  if (runtime.idleTimer) {
    clearTimeout(runtime.idleTimer);
    runtime.idleTimer = null;
  }
}

function resolveIdleTtlMs(): number {
  const raw = Number(process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS ?? DEFAULT_IDLE_TTL_MS);
  if (!Number.isFinite(raw)) return DEFAULT_IDLE_TTL_MS;
  return Math.max(1, Math.floor(raw));
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
