import type { WebSocket } from "ws";

import { BoundedWorkQueue } from "./backpressure.js";
import type { JsonRpcId, JsonRpcResponse } from "./types.js";

export type InitializeCapabilities = {
  experimentalApi: boolean;
  optOutNotificationMethods: Set<string>;
};

type PendingServerRequest = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timeout: NodeJS.Timeout;
};

export class CodexConnectionState {
  readonly ws: WebSocket;
  readonly ingressQueue: BoundedWorkQueue;

  initializedRequestReceived = false;
  initializedNotificationReceived = false;
  capabilities: InitializeCapabilities = {
    experimentalApi: false,
    optOutNotificationMethods: new Set<string>(),
  };

  private serverRequestSeq = 0;
  private pendingServerRequests = new Map<string, PendingServerRequest>();

  constructor(ws: WebSocket, opts: { maxIngressQueueDepth: number }) {
    this.ws = ws;
    this.ingressQueue = new BoundedWorkQueue(opts.maxIngressQueueDepth);
  }

  isReadyForRegularMethods(): boolean {
    return this.initializedRequestReceived && this.initializedNotificationReceived;
  }

  shouldSendNotification(method: string): boolean {
    return !this.capabilities.optOutNotificationMethods.has(method);
  }

  sendResult(id: JsonRpcId, result: unknown) {
    this.sendRaw({ id, result });
  }

  sendError(id: JsonRpcId, code: number, message: string, data?: unknown) {
    this.sendRaw({ id, error: data === undefined ? { code, message } : { code, message, data } });
  }

  sendNotification(method: string, params: unknown) {
    if (!this.shouldSendNotification(method)) return;
    this.sendRaw({ method, params });
  }

  sendServerRequest(method: string, params: unknown, timeoutMs = 5 * 60_000, preferredId?: JsonRpcId): Promise<unknown> {
    const id = preferredId ?? `srvreq_${++this.serverRequestSeq}`;
    const key = typeof id === "string" ? id : String(id);
    if (this.pendingServerRequests.has(key)) {
      return Promise.reject(new Error(`Server request id collision: ${key}`));
    }

    this.sendRaw({ id, method, params });

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingServerRequests.delete(key);
        reject(new Error(`Timed out waiting for client response to ${method}`));
      }, timeoutMs);
      this.pendingServerRequests.set(key, { resolve, reject, timeout });
    });
  }

  handleClientResponse(response: JsonRpcResponse): boolean {
    const key = typeof response.id === "string" ? response.id : String(response.id);
    const pending = this.pendingServerRequests.get(key);
    if (!pending) return false;
    clearTimeout(pending.timeout);
    this.pendingServerRequests.delete(key);
    if (response.error) {
      pending.reject(new Error(response.error.message));
    } else {
      pending.resolve(response.result);
    }
    return true;
  }

  close(err?: Error) {
    for (const pending of this.pendingServerRequests.values()) {
      clearTimeout(pending.timeout);
      pending.reject(err ?? new Error("Connection closed"));
    }
    this.pendingServerRequests.clear();
  }

  private sendRaw(payload: unknown) {
    this.ws.send(JSON.stringify(payload));
  }
}
