import { updateThreadPreviewFromItems } from "./handlers/thread.js";
import { handleInitialize } from "./handlers/initialize.js";
import {
  handleLabosArtifactGet,
  handleLabosArtifactList,
  handleLabosHpcPrefsSet,
  handleLabosProjectCreate,
  handleLabosProjectDelete,
  handleLabosProjectList,
  handleLabosProjectRename,
  handleLabosRunGet,
  handleLabosRunList,
  handleLabosSessionCreate,
  handleLabosSessionDelete,
  handleLabosSessionList,
  handleLabosSessionRead,
  handleLabosSessionUpdate,
} from "./handlers/labos.js";
import { handleModelList } from "./handlers/model.js";
import { handleThreadList, handleThreadRead, handleThreadResume, handleThreadStart } from "./handlers/thread.js";
import { handleTurnInterrupt, handleTurnStart } from "./handlers/turn.js";
import type { CodexConnectionState } from "./connection_state.js";
import type { CodexEngineRegistry } from "./engine_registry.js";
import type { CodexRepository } from "./repository.js";
import { TurnAggregationState } from "./turn_aggregator.js";
import type { JsonRpcNotification, JsonRpcRequest, JsonRpcResponse, Thread, ThreadItem, Turn, TurnStatus } from "./types.js";
import { nowUnixSeconds } from "./types.js";

type CodexRouterContext = {
  repository: CodexRepository;
  engines: CodexEngineRegistry;
  connection: CodexConnectionState;
};

export class CodexRpcRouter {
  private readonly repository: CodexRepository;
  private readonly engines: CodexEngineRegistry;
  private readonly connection: CodexConnectionState;

  private readonly turnAggregators = new Map<string, TurnAggregationState>();

  constructor(ctx: CodexRouterContext) {
    this.repository = ctx.repository;
    this.engines = ctx.engines;
    this.connection = ctx.connection;
  }

  async handleRequest(request: JsonRpcRequest) {
    const method = request.method;

    if (!this.connection.initializedRequestReceived && method !== "initialize") {
      this.connection.sendError(request.id, -32002, "Client must send initialize before calling this method.");
      return;
    }

    if (this.connection.initializedRequestReceived && !this.connection.initializedNotificationReceived && method !== "initialize") {
      this.connection.sendError(request.id, -32002, "Client must send initialized before calling this method.");
      return;
    }

    try {
      const params = normalizeParams(request.params);

      switch (method) {
        case "initialize": {
          if (this.connection.initializedRequestReceived) {
            this.connection.sendError(request.id, -32600, "initialize was already received for this connection.");
            return;
          }
          const result = handleInitialize(this.connection, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "thread/start": {
          const result = await handleThreadStart({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          if (isThreadPayload(result.thread)) {
            await this.persistAndSendNotification("thread/started", {
              thread: result.thread,
            });
          }
          return;
        }
        case "thread/resume": {
          const result = await handleThreadResume({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "thread/read": {
          const result = await handleThreadRead({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "thread/list": {
          const result = await handleThreadList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "turn/start": {
          const prepared = await handleTurnStart({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, {
            threadId: prepared.threadId,
            turn: prepared.turn,
          });

          for (const notification of prepared.preludeNotifications) {
            await this.persistAndSendNotification(notification.method, notification.params);
          }

          void this.consumeTurnEvents({
            threadId: prepared.threadId,
            turnId: prepared.turnId,
            seedTurn: prepared.turn,
            events: prepared.events,
          });
          return;
        }
        case "turn/interrupt": {
          const result = await handleTurnInterrupt({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "model/list": {
          const result = await handleModelList({ engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/project/list": {
          const result = await handleLabosProjectList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/project/create": {
          const result = await handleLabosProjectCreate({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/project/rename": {
          const result = await handleLabosProjectRename({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/project/delete": {
          const result = await handleLabosProjectDelete({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/list": {
          const result = await handleLabosSessionList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/create": {
          const result = await handleLabosSessionCreate({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/update": {
          const result = await handleLabosSessionUpdate({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/delete": {
          const result = await handleLabosSessionDelete({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/read": {
          const result = await handleLabosSessionRead({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/artifact/list": {
          const result = await handleLabosArtifactList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/artifact/get": {
          const result = await handleLabosArtifactGet({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/run/list": {
          const result = await handleLabosRunList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/run/get": {
          const result = await handleLabosRunGet({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/hpc/prefs/set": {
          const result = await handleLabosHpcPrefsSet({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        default: {
          this.connection.sendError(request.id, -32601, `Method not found: ${method}`);
          return;
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.connection.sendError(request.id, -32000, message);
    }
  }

  async handleNotification(notification: JsonRpcNotification) {
    if (notification.method === "initialized") {
      if (!this.connection.initializedRequestReceived) {
        return;
      }
      this.connection.initializedNotificationReceived = true;
    }
  }

  async handleResponse(response: JsonRpcResponse) {
    if (this.connection.handleClientResponse(response)) {
      return;
    }
  }

  async close() {
    await this.engines.close();
  }

  private async consumeTurnEvents(args: {
    threadId: string;
    turnId: string;
    seedTurn: Turn;
    events: AsyncIterable<{ type: string; method: string; params: Record<string, unknown>; respond?: (response: { result?: unknown; error?: { code: number; message: string; data?: unknown } }) => Promise<void> }>;
  }) {
    let sawTurnCompleted = false;

    try {
      for await (const event of args.events) {
        if (event.type === "notification") {
          if (event.method === "turn/completed") {
            sawTurnCompleted = true;
          }
          await this.persistAndSendNotification(event.method, event.params);
          continue;
        }

        if (event.type === "serverRequest") {
          try {
            const response = await this.connection.sendServerRequest(event.method, event.params, 5 * 60_000, event.id);
            if (event.respond) {
              await event.respond({ result: response });
            }
          } catch (err) {
            const message = err instanceof Error ? err.message : String(err);
            if (event.respond) {
              await event.respond({
                error: {
                  code: -32000,
                  message,
                },
              });
            }
          }
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await this.persistAndSendNotification("turn/completed", {
        threadId: args.threadId,
        turn: {
          id: args.turnId,
          items: [],
          status: "failed",
          error: {
            message,
            codexErrorInfo: null,
            additionalDetails: null,
          },
        },
      });
      return;
    }

    if (!sawTurnCompleted) {
      await this.persistAndSendNotification("turn/completed", {
        threadId: args.threadId,
        turn: {
          id: args.turnId,
          items: [],
          status: "completed",
          error: null,
        },
      });
    }
  }

  private async persistAndSendNotification(method: string, params: Record<string, unknown>) {
    const threadId = normalizeNonEmptyString(params.threadId);
    if (!threadId) {
      this.connection.sendNotification(method, params);
      return;
    }

    const threadRecord = await this.repository.getThreadRecord(threadId);
    const projectId = threadRecord?.projectId ?? null;
    const persistTurnItemState = threadRecord?.engine !== "codex-app-server";

    await this.repository.appendThreadEvent({
      threadId,
      projectId,
      event: {
        method,
        params,
      },
      createdAt: nowUnixSeconds(),
    });

    if (persistTurnItemState && method === "turn/started") {
      const turn = params.turn as Record<string, unknown> | undefined;
      const turnId = normalizeNonEmptyString(turn?.id);
      if (turnId) {
        try {
          await this.repository.createTurn({
            id: turnId,
            threadId,
            status: normalizeTurnStatus(turn?.status),
            error: normalizeTurnError(turn?.error),
            createdAt: nowUnixSeconds(),
          });
        } catch {
          // Turn may already exist if this was created before the stream started.
        }
      }
    }

    if (persistTurnItemState && (method === "item/started" || method === "item/completed")) {
      const turnId = normalizeNonEmptyString(params.turnId);
      const itemRaw = params.item as Record<string, unknown> | undefined;
      const itemId = normalizeNonEmptyString(itemRaw?.id);
      const itemType = normalizeNonEmptyString(itemRaw?.type);
      if (turnId && itemId && itemType) {
        await this.repository.upsertItem({
          id: itemId,
          threadId,
          turnId,
          type: itemType,
          payload: itemRaw as ThreadItem,
          updatedAt: nowUnixSeconds(),
        });

        const thread = await this.repository.readThread(threadId, true);
        if (thread) {
          await this.repository.updateThread({
            id: threadId,
            preview: updateThreadPreviewFromItems(thread.turns),
            updatedAt: nowUnixSeconds(),
          });
        }

        if (method === "item/completed") {
          await this.onItemCompleted({ threadId, turnId, item: itemRaw as ThreadItem });
        }
      }
    }

    if (method === "turn/plan/updated") {
      const turnId = normalizeNonEmptyString(params.turnId);
      if (turnId) {
        const aggregator = this.turnAggregators.get(turnId) ?? new TurnAggregationState();
        const planRaw = Array.isArray(params.plan) ? params.plan : [];
        const plan = planRaw
          .map((entry) => {
            if (!entry || typeof entry !== "object") return null;
            const row = entry as Record<string, unknown>;
            const step = normalizeNonEmptyString(row.step);
            const status = normalizePlanStatus(row.status);
            if (!step || !status) return null;
            return { step, status };
          })
          .filter((entry): entry is { step: string; status: "pending" | "inProgress" | "completed" } => entry != null);
        aggregator.updatePlan({
          explanation: normalizeNullableString(params.explanation),
          plan,
        });
        this.turnAggregators.set(turnId, aggregator);
      }
    }

    if (method === "turn/completed") {
      const turn = params.turn as Record<string, unknown> | undefined;
      const turnId = normalizeNonEmptyString(turn?.id);
      if (turnId) {
        if (persistTurnItemState) {
          await this.repository.updateTurn({
            id: turnId,
            status: normalizeTurnStatus(turn?.status),
            error: normalizeTurnError(turn?.error),
            completedAt: nowUnixSeconds(),
            touchThreadId: threadId,
          });
        } else {
          await this.repository.updateThread({
            id: threadId,
            updatedAt: nowUnixSeconds(),
          });
        }
        this.turnAggregators.delete(turnId);
      }
    }

    if (method === "thread/tokenUsage/updated") {
      const tokenUsage = params.tokenUsage as Record<string, unknown> | undefined;
      if (tokenUsage) {
        const contextWindowTokens = normalizeNumericTokenCount(tokenUsage.contextWindow ?? tokenUsage.contextWindowTokens);
        const usedInputTokens = normalizeNumericTokenCount(tokenUsage.inputTokens ?? tokenUsage.totalInputTokens);
        const usedTokens = normalizeNumericTokenCount(tokenUsage.totalTokens ?? tokenUsage.totalInputTokens ?? tokenUsage.inputTokens);
        const modelId = normalizeNonEmptyString(tokenUsage.model) ?? normalizeNonEmptyString(tokenUsage.modelId);

        const mapped = await this.repository.findSessionByThread(threadId);
        if (mapped && contextWindowTokens != null && usedInputTokens != null && usedTokens != null) {
          await this.repository.query(
            `UPDATE sessions
             SET context_model_id=$1,
                 context_window_tokens=$2,
                 context_used_input_tokens=$3,
                 context_used_tokens=$4,
                 context_updated_at=$5
             WHERE project_id=$6 AND id=$7`,
            [modelId, contextWindowTokens, usedInputTokens, usedTokens, new Date().toISOString(), mapped.projectId, mapped.sessionId]
          );
        }
      }
    }

    this.connection.sendNotification(method, params);
  }

  private async onItemCompleted(args: { threadId: string; turnId: string; item: ThreadItem }) {
    const aggregator = this.turnAggregators.get(args.turnId) ?? new TurnAggregationState();
    const diffChanged = aggregator.ingestCompletedItem(args.item);
    if (diffChanged) {
      this.turnAggregators.set(args.turnId, aggregator);
      const diff = aggregator.diffSnapshot();
      await this.persistAndSendNotification("turn/diff/updated", {
        threadId: args.threadId,
        turnId: args.turnId,
        diff,
      });
    }
  }
}

function normalizeParams(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  return raw as Record<string, unknown>;
}

function normalizeTurnStatus(raw: unknown): TurnStatus {
  const value = normalizeNonEmptyString(raw);
  switch (value) {
    case "completed":
    case "interrupted":
    case "failed":
    case "inProgress":
      return value;
    default:
      return "inProgress";
  }
}

function normalizeTurnError(raw: unknown): { message: string; codexErrorInfo: unknown | null; additionalDetails: string | null } | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const message = normalizeNonEmptyString(obj.message);
  if (!message) return null;
  return {
    message,
    codexErrorInfo: obj.codexErrorInfo ?? null,
    additionalDetails: normalizeNullableString(obj.additionalDetails),
  };
}

function normalizeNullableString(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizePlanStatus(raw: unknown): "pending" | "inProgress" | "completed" | null {
  const value = normalizeNonEmptyString(raw);
  if (value === "pending" || value === "inProgress" || value === "completed") {
    return value;
  }
  if (value === "in_progress") {
    return "inProgress";
  }
  return null;
}

function normalizeNumericTokenCount(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return Math.max(0, Math.floor(raw));
  }
  if (typeof raw === "string" && raw.trim()) {
    const parsed = Number(raw);
    if (Number.isFinite(parsed)) {
      return Math.max(0, Math.floor(parsed));
    }
  }
  return null;
}

function isThreadPayload(value: unknown): value is Thread {
  if (!value || typeof value !== "object") return false;
  const obj = value as Record<string, unknown>;
  return typeof obj.id === "string" && typeof obj.cwd === "string";
}
