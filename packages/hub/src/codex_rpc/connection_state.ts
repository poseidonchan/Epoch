import { BoundedWorkQueue } from "./backpressure.js";
import type { JsonRpcId, JsonRpcResponse } from "./types.js";

export type InitializeCapabilities = {
  experimentalApi: boolean;
  optOutNotificationMethods: Set<string>;
};

export type PendingUserInputMetadata = {
  sessionId?: string | null;
  kind?: string | null;
};

export type PendingUserInputSummary = {
  count: number;
  kind: string | null;
};

type WebSocketLike = {
  send: (payload: string) => void;
};

type PendingServerRequest = {
  id: JsonRpcId;
  method: string;
  params: unknown;
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timeout: NodeJS.Timeout | null;
  metadata: PendingUserInputMetadata | null;
};

export class CodexConnectionState {
  readonly ingressQueue: BoundedWorkQueue;

  initializedRequestReceived = false;
  initializedNotificationReceived = false;
  capabilities: InitializeCapabilities = {
    experimentalApi: false,
    optOutNotificationMethods: new Set<string>(),
  };

  private ws: WebSocketLike | null;
  private serverRequestSeq = 0;
  private pendingServerRequests = new Map<string, PendingServerRequest>();

  constructor(ws: WebSocketLike, opts: { maxIngressQueueDepth: number }) {
    this.ws = ws;
    this.ingressQueue = new BoundedWorkQueue(opts.maxIngressQueueDepth);
  }

  attachWebSocket(ws: WebSocketLike) {
    this.ws = ws;
    this.initializedRequestReceived = false;
    this.initializedNotificationReceived = false;
    this.capabilities = {
      experimentalApi: false,
      optOutNotificationMethods: new Set<string>(),
    };
    this.replayPendingServerRequests();
  }

  isAttachedWebSocket(ws: WebSocketLike): boolean {
    return this.ws === ws;
  }

  detachWebSocket(ws?: WebSocketLike) {
    if (!ws || this.ws === ws) {
      this.ws = null;
    }
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

  sendServerRequest(
    method: string,
    params: unknown,
    timeoutMs = 5 * 60_000,
    preferredId?: JsonRpcId,
    metadata?: PendingUserInputMetadata
  ): Promise<unknown> {
    const id = preferredId ?? `srvreq_${++this.serverRequestSeq}`;
    const key = typeof id === "string" ? id : String(id);
    if (this.pendingServerRequests.has(key)) {
      return Promise.reject(new Error(`Server request id collision: ${key}`));
    }

    return new Promise((resolve, reject) => {
      const normalizedMetadata = normalizePendingMetadata(metadata);
      const timeout =
        normalizedMetadata?.sessionId != null
          ? null
          : setTimeout(() => {
              this.pendingServerRequests.delete(key);
              reject(new Error(`Timed out waiting for client response to ${method}`));
            }, timeoutMs);

      const pending: PendingServerRequest = {
        id,
        method,
        params,
        resolve,
        reject,
        timeout,
        metadata: normalizedMetadata,
      };
      this.pendingServerRequests.set(key, pending);
      this.sendRaw({
        id: pending.id,
        method: pending.method,
        params: pending.params,
      });
    });
  }

  pendingUserInputSummaryMap(): Map<string, PendingUserInputSummary> {
    const summary = new Map<string, PendingUserInputSummary>();
    for (const pending of this.pendingServerRequests.values()) {
      const sessionId = normalizeNonEmptyString(pending.metadata?.sessionId);
      if (!sessionId) continue;
      const next = summary.get(sessionId) ?? { count: 0, kind: null };
      next.count += 1;
      if (!next.kind) {
        next.kind = normalizeNonEmptyString(pending.metadata?.kind);
      }
      summary.set(sessionId, next);
    }
    return summary;
  }

  handleClientResponse(response: JsonRpcResponse): boolean {
    const key = typeof response.id === "string" ? response.id : String(response.id);
    const pending = this.pendingServerRequests.get(key);
    if (!pending) return false;
    if (pending.timeout) {
      clearTimeout(pending.timeout);
    }
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
      if (pending.timeout) {
        clearTimeout(pending.timeout);
      }
      pending.reject(err ?? new Error("Connection closed"));
    }
    this.pendingServerRequests.clear();
    this.ws = null;
  }

  private replayPendingServerRequests() {
    for (const pending of this.pendingServerRequests.values()) {
      this.sendRaw({
        id: pending.id,
        method: pending.method,
        params: pending.params,
      });
    }
  }

  private sendRaw(payload: unknown) {
    if (!this.ws) return;
    try {
      this.ws.send(JSON.stringify(payload));
    } catch {
      this.ws = null;
    }
  }
}

function normalizePendingMetadata(metadata: PendingUserInputMetadata | undefined): PendingUserInputMetadata | null {
  if (!metadata) return null;
  const sessionId = normalizeNonEmptyString(metadata.sessionId);
  const kind = normalizeNonEmptyString(metadata.kind);
  if (!sessionId && !kind) return null;
  return {
    ...(sessionId ? { sessionId } : {}),
    ...(kind ? { kind } : {}),
  };
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}
