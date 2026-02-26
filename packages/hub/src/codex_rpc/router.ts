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
  handleLabosProjectUpdate,
  handleLabosRunGet,
  handleLabosRunList,
  handleLabosSessionCreate,
  handleLabosSessionDelete,
  handleLabosSessionList,
  handleLabosSessionRead,
  handleLabosSessionUpdate,
} from "./handlers/labos.js";
import { handleModelList } from "./handlers/model.js";
import { handleSkillsList } from "./handlers/skills.js";
import { handleThreadList, handleThreadRead, handleThreadResume, handleThreadRollback, handleThreadStart } from "./handlers/thread.js";
import { handleTurnInterrupt, handleTurnStart, handleTurnSteer } from "./handlers/turn.js";
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
  token: string;
};

export class CodexRpcRouter {
  private readonly repository: CodexRepository;
  private readonly engines: CodexEngineRegistry;
  private readonly connection: CodexConnectionState;
  private readonly token: string;

  private readonly turnAggregators = new Map<string, TurnAggregationState>();
  private readonly turnPlanModeByScopedTurnId = new Map<string, boolean>();

  constructor(ctx: CodexRouterContext) {
    this.repository = ctx.repository;
    this.engines = ctx.engines;
    this.connection = ctx.connection;
    this.token = ctx.token;
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
        case "thread/rollback": {
          const result = await handleThreadRollback({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "thread/list": {
          const result = await handleThreadList({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "turn/start": {
          await this.cancelPendingImplementConfirmationForTurnRequest(params);
          const prepared = await handleTurnStart({ repository: this.repository, engines: this.engines }, params);
          this.turnPlanModeByScopedTurnId.set(scopedTurnId(prepared.threadId, prepared.turnId), prepared.planMode);
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
        case "turn/steer": {
          await this.cancelPendingImplementConfirmationForTurnRequest(params);
          const result = await handleTurnSteer({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "model/list": {
          const result = await handleModelList({ engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "skills/list": {
          const result = await handleSkillsList({ engines: this.engines }, params);
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
        case "labos/project/update": {
          const result = await handleLabosProjectUpdate({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/project/delete": {
          const result = await handleLabosProjectDelete({ repository: this.repository, engines: this.engines }, params);
          this.connection.sendResult(request.id, result);
          return;
        }
        case "labos/session/list": {
          const result = await handleLabosSessionList(
            {
              repository: this.repository,
              engines: this.engines,
              pendingUserInputSummaryBySession: this.connection.pendingUserInputSummaryMap(),
              runtimeToken: this.token,
            },
            params
          );
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
          const result = await handleLabosSessionRead(
            {
              repository: this.repository,
              engines: this.engines,
              pendingUserInputSummaryBySession: this.connection.pendingUserInputSummaryMap(),
              runtimeToken: this.token,
            },
            params
          );
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

  private async cancelPendingImplementConfirmationForTurnRequest(params: Record<string, unknown>) {
    const sessionId = await this.resolveSessionIdForTurnRequest(params);
    if (!sessionId) return;
    await this.cancelPendingImplementConfirmationForSession(sessionId);
  }

  private async resolveSessionIdForTurnRequest(params: Record<string, unknown>): Promise<string | null> {
    const sessionId = normalizeNonEmptyString(params.sessionId);
    if (sessionId) return sessionId;

    const threadId = normalizeNonEmptyString(params.threadId);
    if (!threadId) return null;
    const mapped = await this.repository.findSessionByThread(threadId);
    return mapped?.sessionId ?? null;
  }

  private async cancelPendingImplementConfirmationForSession(sessionId: string) {
    const pending = await this.repository.listPendingInputsForSession({
      sessionId,
      token: this.token,
    });
    const implementConfirmations = pending.filter((entry) => entry.kind === "implement_confirmation");
    if (implementConfirmations.length === 0) return;

    for (const entry of implementConfirmations) {
      await this.repository.resolvePendingInput({
        token: this.token,
        requestId: entry.requestId,
        status: "resolved",
      });
    }
    this.connection.cancelPendingServerRequests({
      sessionId,
      kind: "implement_confirmation",
      reason: "Implement confirmation superseded by new user turn input.",
    });
  }

  private async consumeTurnEvents(args: {
    threadId: string;
    turnId: string;
    seedTurn: Turn;
    events: AsyncIterable<{ type: string; id?: string | number; method: string; params: Record<string, unknown>; respond?: (response: { result?: unknown; error?: { code: number; message: string; data?: unknown } }) => Promise<void> }>;
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
          let persistedPendingRequestId: string | null = null;
          try {
            const dynamicPlanUpdate = extractPlanUpdateFromDynamicToolCall(event.method, event.params);
            if (dynamicPlanUpdate) {
              await this.persistAndSendNotification("turn/plan/updated", {
                threadId: args.threadId,
                turnId: dynamicPlanUpdate.turnId,
                explanation: dynamicPlanUpdate.explanation,
                plan: dynamicPlanUpdate.plan,
              });
            }
            const sessionMapping = await this.repository.findSessionByThread(args.threadId);
            const pendingKind = pendingInputKindForMethod(event.method, event.params);
            const preferredRequestId =
              event.id ?? `labos_srvreq_${Date.now()}_${Math.floor(Math.random() * 1_000_000)}`;
            if (pendingKind && sessionMapping) {
              const requestId = requestIdKey(preferredRequestId);
              persistedPendingRequestId = requestId;
              await this.repository.upsertPendingInput({
                token: this.token,
                requestId,
                sessionId: sessionMapping.sessionId,
                threadId: args.threadId,
                method: event.method,
                kind: pendingKind,
                params: event.params,
              });
            }
            const response = await this.connection.sendServerRequest(
              event.method,
              event.params,
              5 * 60_000,
              preferredRequestId,
              pendingKind && sessionMapping
                ? {
                    sessionId: sessionMapping.sessionId,
                    kind: pendingKind,
                  }
                : undefined
            );
            if (persistedPendingRequestId) {
              await this.repository.resolvePendingInput({
                token: this.token,
                requestId: persistedPendingRequestId,
                status: "resolved",
              });
            }
            if (event.respond) {
              await event.respond({ result: response });
            }
          } catch (err) {
            if (persistedPendingRequestId && shouldResolvePendingRequestOnError(err)) {
              await this.repository.resolvePendingInput({
                token: this.token,
                requestId: persistedPendingRequestId,
                status: "resolved",
              });
            }
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
    const sessionMapping = await this.repository.findSessionByThread(threadId);
    // Persist turn/item lifecycle for all engines so sessions can switch backends
    // without losing replayable history.
    const persistTurnItemState = true;

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
        await this.resolveOrCreatePersistedTurnId({
          threadId,
          rawTurnId: turnId,
          status: normalizeTurnStatus(turn?.status),
          error: normalizeTurnError(turn?.error),
        });
      }
    }

    if (persistTurnItemState && (method === "item/started" || method === "item/completed")) {
      const turnId = normalizeNonEmptyString(params.turnId);
      const itemRaw = params.item as Record<string, unknown> | undefined;
      const itemId = normalizeNonEmptyString(itemRaw?.id);
      const itemType = normalizeNonEmptyString(itemRaw?.type);
      if (turnId && itemId && itemType) {
        const persistedTurnId = await this.resolveOrCreatePersistedTurnId({
          threadId,
          rawTurnId: turnId,
          status: "inProgress",
          error: null,
        });

        await this.repository.upsertItem({
          id: scopedItemId(threadId, itemId),
          threadId,
          turnId: persistedTurnId,
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
        if (sessionMapping && plan.length > 0) {
          await this.repository.upsertPlanSnapshot({
            sessionId: sessionMapping.sessionId,
            token: this.token,
            threadId,
            turnId,
            explanation: normalizeNullableString(params.explanation),
            plan,
          });
        }
      }
    }

    let completedTurnId: string | null = null;
    let shouldRequestPlanImplementation = false;
    let implementationSessionId: string | null = null;
    if (method === "turn/completed") {
      const turn = params.turn as Record<string, unknown> | undefined;
      const turnId = normalizeNonEmptyString(turn?.id);
      if (turnId) {
        completedTurnId = turnId;
        const persistedTurnId = await this.resolveOrCreatePersistedTurnId({
          threadId,
          rawTurnId: turnId,
          status: normalizeTurnStatus(turn?.status),
          error: normalizeTurnError(turn?.error),
        });

        if (persistTurnItemState) {
          await this.repository.updateTurn({
            id: persistedTurnId,
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
        if (sessionMapping) {
          await this.repository.clearPlanSnapshotForSession({
            sessionId: sessionMapping.sessionId,
            token: this.token,
          });
        }
        const scopedCompletedTurnId = scopedTurnId(threadId, turnId);
        const wasPlanModeTurn = this.turnPlanModeByScopedTurnId.get(scopedCompletedTurnId) === true;
        this.turnPlanModeByScopedTurnId.delete(scopedCompletedTurnId);
        const status = normalizeTurnStatus(turn?.status);
        if (wasPlanModeTurn && status === "completed" && sessionMapping) {
          shouldRequestPlanImplementation = true;
          implementationSessionId = sessionMapping.sessionId;
        }
        this.turnAggregators.delete(turnId);
      }
    }

    if (method === "thread/tokenUsage/updated") {
      const tokenUsage = params.tokenUsage as Record<string, unknown> | undefined;
      if (tokenUsage) {
        const lastUsage = normalizeObject(tokenUsage.last);
        const totalUsage = normalizeObject(tokenUsage.total);
        const contextWindowTokens = normalizeNumericTokenCount(
          tokenUsage.modelContextWindow ?? tokenUsage.contextWindow ?? tokenUsage.contextWindowTokens
        );
        const usedInputTokens = normalizeNumericTokenCount(
          lastUsage?.inputTokens ?? tokenUsage.inputTokens ?? tokenUsage.totalInputTokens ?? totalUsage?.inputTokens
        );
        const usedTokens = normalizeNumericTokenCount(
          lastUsage?.totalTokens ??
            tokenUsage.totalTokens ??
            totalUsage?.totalTokens ??
            tokenUsage.totalInputTokens ??
            tokenUsage.inputTokens
        );
        const modelId =
          normalizeNonEmptyString(tokenUsage.model) ??
          normalizeNonEmptyString(tokenUsage.modelId) ??
          normalizeNonEmptyString(lastUsage?.model) ??
          normalizeNonEmptyString(totalUsage?.model);

        const mapped = await this.repository.findSessionByThread(threadId);
        if (mapped && contextWindowTokens != null && usedInputTokens != null && usedTokens != null) {
          await this.repository.query(
            `UPDATE sessions
             SET context_model_id=COALESCE($1, context_model_id),
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

    if (shouldRequestPlanImplementation && completedTurnId && implementationSessionId) {
      void this
        .requestPlanImplementationConfirmation({
          threadId,
          turnId: completedTurnId,
          sessionId: implementationSessionId,
        })
        .catch(() => {});
    }
  }

  private async requestPlanImplementationConfirmation(args: {
    threadId: string;
    turnId: string;
    sessionId: string;
  }) {
    // Avoid issuing duplicate implement-confirmation prompts for the same session.
    const pending = await this.repository.listPendingInputsForSession({
      sessionId: args.sessionId,
      token: this.token,
    });
    if (pending.some((entry) => entry.kind === "implement_confirmation")) {
      return;
    }

    const thread = await this.repository.readThread(args.threadId, true);
    if (!thread) return;
    const completedTurn = findTurnByIdVariants(thread, args.threadId, args.turnId);
    if (!completedTurn) return;
    if (!turnContainsImplementablePlan(completedTurn)) return;
    if (threadHasNewerUserTurnAfter(thread, args.threadId, args.turnId)) return;

    const requestId = `labos_impl_${Date.now()}_${Math.floor(Math.random() * 1_000_000)}`;
    const params = buildPlanImplementationPromptParams({
      threadId: args.threadId,
      turnId: args.turnId,
    });

    await this.repository.upsertPendingInput({
      token: this.token,
      requestId,
      sessionId: args.sessionId,
      threadId: args.threadId,
      method: "item/tool/requestUserInput",
      kind: "implement_confirmation",
      params,
    });

    let response: unknown;
    try {
      response = await this.connection.sendServerRequest(
        "item/tool/requestUserInput",
        params,
        5 * 60_000,
        requestId,
        {
          sessionId: args.sessionId,
          kind: "implement_confirmation",
        }
      );
      await this.repository.resolvePendingInput({
        token: this.token,
        requestId,
        status: "resolved",
      });
    } catch (err) {
      if (shouldResolvePendingRequestOnError(err)) {
        await this.repository.resolvePendingInput({
          token: this.token,
          requestId,
          status: "resolved",
        });
      }
      return;
    }

    const followup = decidePlanImplementationFollowup(response);
    if (!followup) return;
    await this.startFollowupTurn({
      threadId: args.threadId,
      sessionId: args.sessionId,
      text: followup.text,
      planMode: followup.planMode,
    });
  }

  private async startFollowupTurn(args: {
    threadId: string;
    sessionId: string;
    text: string;
    planMode: boolean;
  }) {
    const prepared = await handleTurnStart(
      {
        repository: this.repository,
        engines: this.engines,
      },
      {
        threadId: args.threadId,
        sessionId: args.sessionId,
        input: [
          {
            type: "text",
            text: args.text,
            text_elements: [],
          },
        ],
        planMode: args.planMode,
      }
    );
    this.turnPlanModeByScopedTurnId.set(scopedTurnId(prepared.threadId, prepared.turnId), prepared.planMode);
    for (const notification of prepared.preludeNotifications) {
      await this.persistAndSendNotification(notification.method, notification.params);
    }
    void this.consumeTurnEvents({
      threadId: prepared.threadId,
      turnId: prepared.turnId,
      seedTurn: prepared.turn,
      events: prepared.events,
    });
  }

  private async resolveOrCreatePersistedTurnId(args: {
    threadId: string;
    rawTurnId: string;
    status: TurnStatus;
    error: { message: string; codexErrorInfo: unknown | null; additionalDetails: string | null } | null;
  }): Promise<string> {
    const rawTurnId = args.rawTurnId.trim();
    const scoped = scopedTurnId(args.threadId, rawTurnId);
    const existing = await this.repository.query<{ id: string }>(
      `SELECT id
       FROM turns
       WHERE thread_id=$1 AND (id=$2 OR id=$3)
       ORDER BY CASE WHEN id=$2 THEN 0 ELSE 1 END
       LIMIT 1`,
      [args.threadId, scoped, rawTurnId]
    );
    if (existing.length > 0) {
      return String(existing[0]?.id ?? scoped);
    }

    try {
      await this.repository.createTurn({
        id: scoped,
        threadId: args.threadId,
        status: args.status,
        error: args.error,
        createdAt: nowUnixSeconds(),
      });
    } catch {
      // Another event may create the same row first.
    }
    return scoped;
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

function pendingInputKindForMethod(method: string, params?: Record<string, unknown>): string | null {
  if (method === "item/tool/requestUserInput") {
    const firstQuestionId = firstPromptQuestionId(params);
    if (firstQuestionId === "labos_plan_implementation_decision") {
      return "implement_confirmation";
    }
    return "prompt";
  }
  if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
    return "approval";
  }
  return null;
}

function firstPromptQuestionId(params?: Record<string, unknown>): string | null {
  const questions = params?.questions;
  if (!Array.isArray(questions) || questions.length === 0) return null;
  const first = questions[0];
  if (!first || typeof first !== "object" || Array.isArray(first)) return null;
  return normalizeNonEmptyString((first as Record<string, unknown>).id);
}

function requestIdKey(id: string | number): string {
  return typeof id === "string" ? id : String(id);
}

function shouldResolvePendingRequestOnError(err: unknown): boolean {
  const message = String(err instanceof Error ? err.message : err ?? "")
    .trim()
    .toLowerCase();
  if (!message) return false;
  if (message.includes("connection closed") || message.includes("hub shutdown")) return false;
  return true;
}

function findTurnByIdVariants(thread: Thread, threadId: string, turnId: string): Turn | null {
  const scopedId = scopedTurnId(threadId, turnId);
  return (
    thread.turns.find((turn) => {
      const id = turn.id.trim();
      return id === turnId || id === scopedId;
    }) ?? null
  );
}

function threadHasNewerUserTurnAfter(thread: Thread, threadId: string, turnId: string): boolean {
  const scopedId = scopedTurnId(threadId, turnId);
  const completedIndex = thread.turns.findIndex((turn) => {
    const id = turn.id.trim();
    return id === turnId || id === scopedId;
  });
  if (completedIndex < 0) return false;

  for (let index = completedIndex + 1; index < thread.turns.length; index += 1) {
    const turn = thread.turns[index];
    if (turn.items.some((item) => item.type === "userMessage")) {
      return true;
    }
  }
  return false;
}

export function turnContainsProposedPlanBlock(turn: Turn): boolean {
  for (const item of turn.items) {
    if (item.type !== "agentMessage") continue;
    const text = normalizeNonEmptyString((item as Record<string, unknown>).text);
    if (!text) continue;
    if (text.includes("<proposed_plan>") && text.includes("</proposed_plan>")) {
      return true;
    }
  }
  return false;
}

export function turnContainsImplementablePlan(turn: Turn): boolean {
  if (turnContainsProposedPlanBlock(turn)) return true;

  for (const item of turn.items) {
    if (item.type !== "plan") continue;
    const text = normalizeNonEmptyString((item as Record<string, unknown>).text);
    if (text) return true;
  }

  return false;
}

export function buildPlanImplementationPromptParams(args: { threadId: string; turnId: string }): Record<string, unknown> {
  return {
    threadId: args.threadId,
    turnId: args.turnId,
    itemId: `labos_plan_implementation_${args.turnId}`,
    prompt: "Implement this plan?",
    questions: [
      {
        id: "labos_plan_implementation_decision",
        question: "",
        isOther: true,
        isSecret: false,
        options: [
          {
            label: "Yes, implement this plan",
            description: "Start implementing the approved plan immediately.",
          },
          {
            label: "No, and tell Codex what to do differently",
            description: "Close this prompt and continue from the composer.",
          },
        ],
      },
    ],
  };
}

function normalizePlanImplementationDecision(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/\s+/g, " ")
    .replace(/[.!?]+$/g, "");
}

export function decidePlanImplementationFollowup(
  response: unknown
): { planMode: boolean; text: string } | null {
  if (!response || typeof response !== "object" || Array.isArray(response)) return null;
  const result = response as Record<string, unknown>;
  const answers = result.answers;
  if (!answers || typeof answers !== "object" || Array.isArray(answers)) return null;
  const entry = (answers as Record<string, unknown>).labos_plan_implementation_decision;
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
  const answerList = (entry as Record<string, unknown>).answers;
  if (!Array.isArray(answerList) || answerList.length === 0) return null;
  const raw = normalizeNonEmptyString(answerList[0]);
  if (!raw) return null;

  const normalized = normalizePlanImplementationDecision(raw);
  if (
    normalized === "yes, implement this plan" ||
    normalized === "yes implement this plan" ||
    normalized === "implement now" ||
    normalized === "implement it" ||
    normalized === "implement plan"
  ) {
    return {
      planMode: false,
      text: "Implement it",
    };
  }
  return null;
}

export function extractPlanUpdateFromDynamicToolCall(
  method: string,
  params: Record<string, unknown> | null | undefined
): {
  turnId: string;
  explanation: string | null;
  plan: Array<{ step: string; status: "pending" | "inProgress" | "completed" }>;
} | null {
  if (method !== "item/tool/call") return null;
  if (!params || typeof params !== "object" || Array.isArray(params)) return null;

  const tool = normalizeNonEmptyString(params.tool);
  if (!tool || tool.toLowerCase() !== "update_plan") return null;

  const turnId = normalizeNonEmptyString(params.turnId);
  if (!turnId) return null;

  const argumentsRaw = params.arguments;
  if (!argumentsRaw || typeof argumentsRaw !== "object" || Array.isArray(argumentsRaw)) return null;
  const argumentsObject = argumentsRaw as Record<string, unknown>;
  const planRaw = Array.isArray(argumentsObject.plan) ? argumentsObject.plan : [];
  const plan = planRaw
    .map((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null;
      const row = entry as Record<string, unknown>;
      const step = normalizeNonEmptyString(row.step);
      const status = normalizePlanStatus(row.status);
      if (!step || !status) return null;
      return { step, status };
    })
    .filter((entry): entry is { step: string; status: "pending" | "inProgress" | "completed" } => entry != null);

  if (plan.length === 0) return null;

  return {
    turnId,
    explanation: normalizeNullableString(argumentsObject.explanation),
    plan,
  };
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

function normalizeObject(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  return raw as Record<string, unknown>;
}

function scopedTurnId(threadId: string, turnId: string): string {
  const normalizedThread = threadId.trim();
  const normalizedTurn = turnId.trim();
  if (!normalizedThread || !normalizedTurn) return normalizedTurn;
  const prefix = `${normalizedThread}::turn::`;
  return normalizedTurn.startsWith(prefix) ? normalizedTurn : `${prefix}${normalizedTurn}`;
}

function scopedItemId(threadId: string, itemId: string): string {
  const normalizedThread = threadId.trim();
  const normalizedItem = itemId.trim();
  if (!normalizedThread || !normalizedItem) return normalizedItem;
  const prefix = `${normalizedThread}::item::`;
  return normalizedItem.startsWith(prefix) ? normalizedItem : `${prefix}${normalizedItem}`;
}

function isThreadPayload(value: unknown): value is Thread {
  if (!value || typeof value !== "object") return false;
  const obj = value as Record<string, unknown>;
  return typeof obj.id === "string" && typeof obj.cwd === "string";
}
