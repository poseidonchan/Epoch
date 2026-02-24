import type { IncomingMessage } from "node:http";

import type { WebSocket } from "ws";

import type { HubConfig } from "../config.js";
import type { DbPool } from "../db/db.js";
import { CodexConnectionState } from "./connection_state.js";
import { CodexEngineRegistry } from "./engine_registry.js";
import { CodexRepository } from "./repository.js";
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
};

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
  const { ws, config, stateDir, pool } = options;

  const connection = new CodexConnectionState(ws, {
    maxIngressQueueDepth: Number(process.env.LABOS_CODEX_MAX_INGRESS_QUEUE ?? "128"),
  });
  const repository = new CodexRepository({ pool, stateDir });
  const engines = new CodexEngineRegistry({ config, stateDir });
  const router = new CodexRpcRouter({
    repository,
    engines,
    connection,
  });

  ws.on("message", (data) => {
    const text = data.toString();
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      ws.close(4400, "bad json");
      return;
    }

    const accepted = connection.ingressQueue.enqueue(async () => {
      await dispatchInboundMessage(router, parsed);
    });

    if (!accepted) {
      const maybeRequest = parsed as Partial<JsonRpcRequest>;
      if (maybeRequest && (typeof maybeRequest.id === "string" || typeof maybeRequest.id === "number")) {
        connection.sendError(maybeRequest.id, OVERLOAD_ERROR_CODE, OVERLOAD_ERROR_MESSAGE);
      }
    }
  });

  ws.on("close", () => {
    connection.close();
    void router.close();
  });

  ws.on("error", () => {
    connection.close();
    void router.close();
  });
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
