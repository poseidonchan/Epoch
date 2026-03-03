import { v4 as uuidv4 } from "uuid";

import { getEnvApiKey, listHubModelsForProvider, resolveHubProvider } from "../../model.js";
import { loadOpenAIApiKeyFromStateDir } from "../../openai_settings.js";
import {
  makeAgentMessageCompletedNotification,
  makeAgentMessageDeltaNotification,
  makeAgentMessageStartedNotification,
  makeCommandExecutionApprovalRequest,
  makeTurnCompletedNotification,
  makeTurnStartedNotification,
  makeFileChangeApprovalRequest,
} from "../payload_shapes.js";
import type { ThreadItem, Turn, UserInput } from "../types.js";
import { AsyncPushQueue, flattenUserInputToText, type CodexEngineSession, type EngineStartTurnArgs, type EngineStartTurnResult, type EngineStreamEvent } from "./types.js";

type OpenAIResponsesToolDefinition = {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
};

type OpenAIResponsesToolCall = {
  callId: string;
  name: string;
  arguments: Record<string, unknown>;
};

type OpenAIResponsesResponse = {
  id?: string;
  output_text?: string | null;
  output?: Array<Record<string, unknown>> | null;
};

class AbortTurnError extends Error {
  constructor() {
    super("Turn aborted");
    this.name = "AbortTurnError";
  }
}

class TurnLimitError extends Error {
  readonly limit: "maxTurnMs" | "maxToolSteps";
  readonly maxTurnMs: number | null;
  readonly elapsedMs: number | null;
  readonly maxToolSteps: number | null;

  constructor(
    limit: TurnLimitError["limit"],
    args: { maxTurnMs: number; elapsedMs: number } | { maxToolSteps: number }
  ) {
    const message = (() => {
      if (limit === "maxTurnMs") {
        const { elapsedMs, maxTurnMs } = args as { maxTurnMs: number; elapsedMs: number };
        return `Turn exceeded time budget (${elapsedMs}ms > ${maxTurnMs}ms).`;
      }
      const { maxToolSteps } = args as { maxToolSteps: number };
      return `Turn exceeded tool-call budget (${maxToolSteps} steps).`;
    })();
    super(message);
    this.name = "TurnLimitError";
    this.limit = limit;
    this.maxTurnMs = limit === "maxTurnMs" ? (args as { maxTurnMs: number; elapsedMs: number }).maxTurnMs : null;
    this.elapsedMs = limit === "maxTurnMs" ? (args as { maxTurnMs: number; elapsedMs: number }).elapsedMs : null;
    this.maxToolSteps = limit === "maxToolSteps" ? (args as { maxToolSteps: number }).maxToolSteps : null;
  }
}

class RuntimeRequestError extends Error {
  readonly engineName: string;
  readonly method: string;
  readonly cwd: string | null;
  readonly command0: string | null;

  constructor(message: string, args: { engineName: string; method: string; cwd: string | null; command0: string | null }) {
    super(message);
    this.name = "RuntimeRequestError";
    this.engineName = args.engineName;
    this.method = args.method;
    this.cwd = args.cwd;
    this.command0 = args.command0;
  }
}

export class EpochHpcEngine implements CodexEngineSession {
  readonly name = "epoch-hpc";

  private readonly stateDir: string;
  private readonly baseUrl: string;
  private readonly activeTurns = new Map<string, AbortController>();

  constructor(opts: { stateDir: string }) {
    this.stateDir = opts.stateDir;
    this.baseUrl = (process.env.EPOCH_OPENAI_BASE_URL?.trim() || "https://api.openai.com").replace(/\/+$/, "");
  }

  async modelList(_params: Record<string, unknown>): Promise<Record<string, unknown>> {
    const provider = resolveHubProvider(null);
    const providers = Array.from(
      new Set([provider.provider, "openai-codex", "anthropic"].filter(Boolean))
    );

    const models = providers.flatMap((p) => listHubModelsForProvider(p).map((m) => ({ provider: p, ...m })));
    const defaultModelId = provider.defaultModelId ?? (models[0]?.id ?? null);

    const data = models.map((m) => ({
      id: m.id,
      model: m.id,
      upgrade: null,
      displayName: m.name,
      description: `${m.provider}${m.reasoning ? " (reasoning)" : ""}`,
      supportedReasoningEfforts: m.reasoning
        ? [
            { reasoningEffort: "minimal", description: "Fast, lightweight reasoning." },
            { reasoningEffort: "low", description: "Light reasoning." },
            { reasoningEffort: "medium", description: "Balanced reasoning." },
            { reasoningEffort: "high", description: "Deeper reasoning." },
            { reasoningEffort: "xhigh", description: "Maximum reasoning (slower)." },
          ]
        : [{ reasoningEffort: "none", description: "No additional reasoning." }],
      defaultReasoningEffort: m.reasoning ? "medium" : "none",
      inputModalities: ["text", "image"],
      supportsPersonality: false,
      isDefault: Boolean(defaultModelId && m.id === defaultModelId),
    }));

    return { data, nextCursor: null };
  }

  async skillsList(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    const cwds = Array.isArray(params.cwds) ? params.cwds.map((c) => String(c)).filter(Boolean) : [];
    const resolvedCwds = cwds.length > 0 ? cwds : [process.cwd()];
    return {
      data: resolvedCwds.map((cwd) => ({
        cwd,
        skills: [],
        errors: [],
      })),
    };
  }

  async startTurn(args: EngineStartTurnArgs): Promise<EngineStartTurnResult> {
    const queue = new AsyncPushQueue<EngineStreamEvent>();
    const turn: Turn = {
      id: args.turnId,
      items: [],
      status: "inProgress",
      error: null,
    };

    const key = this.turnKey(args.threadId, args.turnId);
    const controller = new AbortController();
    this.activeTurns.set(key, controller);

    void this.runTurn(args, queue, controller.signal)
      .catch((err) => {
        const message = err instanceof Error ? err.message : String(err);
        queue.push({
          type: "notification",
          ...makeTurnCompletedNotification({
            threadId: args.threadId,
            turnId: args.turnId,
            status: err instanceof AbortTurnError ? "interrupted" : "failed",
            error: err instanceof AbortTurnError
              ? null
              : {
                  message,
                  codexErrorInfo: null,
                  additionalDetails: this.buildAdditionalDetailsForTurnError(err),
                },
          }),
        });
      })
      .finally(() => {
        this.activeTurns.delete(key);
        queue.finish();
      });

    return { turn, events: queue };
  }

  async interruptTurn(args: { threadId: string; turnId: string }): Promise<void> {
    const key = this.turnKey(args.threadId, args.turnId);
    const controller = this.activeTurns.get(key);
    if (controller) controller.abort();
  }

  async close(): Promise<void> {
    for (const controller of this.activeTurns.values()) {
      controller.abort();
    }
    this.activeTurns.clear();
  }

  private turnKey(threadId: string, turnId: string): string {
    return `${threadId}::${turnId}`;
  }

  private async runTurn(args: EngineStartTurnArgs, queue: AsyncPushQueue<EngineStreamEvent>, signal: AbortSignal) {
    if (signal.aborted) throw new AbortTurnError();

    const apiKey = (await loadOpenAIApiKeyFromStateDir(this.stateDir)) ?? getEnvApiKey("openai");
    if (!apiKey) {
      throw new Error("Missing OpenAI credentials. Configure an API key (epoch-hub config) or set OPENAI_API_KEY.");
    }

    const model = String(args.model ?? "").trim();
    if (!model) {
      throw new Error("Missing model for epoch-hpc engine");
    }

    const developerInstructions = normalizeNonEmptyString(args.collaborationMode?.settings?.developer_instructions);
    const tools = this.buildToolDefinitions(Boolean(args.collaborationMode?.mode === "plan"));

    // Turn lifecycle
    queue.push({
      type: "notification",
      ...makeTurnStartedNotification({ threadId: args.threadId, turnId: args.turnId }),
    });

    // Record the user input as an item so it persists in thread history.
    const userItemId = `item_user_${uuidv4()}`;
    const userItem: ThreadItem = { type: "userMessage", id: userItemId, content: args.input };
    queue.push({
      type: "notification",
      method: "item/started",
      params: { threadId: args.threadId, turnId: args.turnId, item: userItem },
    });
    queue.push({
      type: "notification",
      method: "item/completed",
      params: { threadId: args.threadId, turnId: args.turnId, item: userItem },
    });

    // Prepare agent message item to stream deltas into.
    const agentItemId = `item_agent_${uuidv4()}`;
    queue.push({ type: "notification", ...makeAgentMessageStartedNotification({ threadId: args.threadId, turnId: args.turnId, itemId: agentItemId }) });

    const baseInput = buildResponsesInput({
      developerInstructions,
      historyTurns: Array.isArray(args.historyTurns) ? args.historyTurns : [],
      userInput: args.input,
    });

    const turnStartedAt = Date.now();
    const maxToolSteps = 256;
    const maxTurnMs = 20 * 60_000;

    const normalizedApprovalPolicy = String(args.approvalPolicy ?? "").trim().toLowerCase();

    let accumulatedText = "";
    const onDelta = (delta: string) => {
      accumulatedText += delta;
      queue.push({
        type: "notification",
        ...makeAgentMessageDeltaNotification({
          threadId: args.threadId,
          turnId: args.turnId,
          itemId: agentItemId,
          delta,
        }),
      });
    };

    let response = await this.createResponses(apiKey, {
      model,
      input: baseInput,
      tools,
      signal,
      onDelta,
    });

    let exhaustedToolSteps = true;
    for (let step = 0; step < maxToolSteps; step += 1) {
      if (signal.aborted) throw new AbortTurnError();
      if (Date.now() - turnStartedAt > maxTurnMs) {
        throw new TurnLimitError("maxTurnMs", {
          maxTurnMs,
          elapsedMs: Date.now() - turnStartedAt,
        });
      }

      const toolCalls = extractToolCalls(response);
      if (toolCalls.length === 0) {
        exhaustedToolSteps = false;
        break;
      }

      const toolCallConcurrency = normalizedApprovalPolicy !== "never" || toolCalls.some((call) => call.name.toLowerCase() === "request_user_input")
        ? 1
        : 4;

      const toolOutputs = await mapWithConcurrency(toolCalls, toolCallConcurrency, async (call) => {
        if (signal.aborted) throw new AbortTurnError();
        const output = await this.executeToolCall({
          threadId: args.threadId,
          turnId: args.turnId,
          cwd: args.cwd,
          approvalPolicy: args.approvalPolicy,
          call,
          queue,
          signal,
        });
        return {
          type: "function_call_output",
          call_id: call.callId,
          output: JSON.stringify(output ?? null),
        };
      });

      const responseId = normalizeNonEmptyString(response.id);
      if (!responseId) {
        throw new Error("OpenAI responses did not return an id for tool continuation");
      }

      response = await this.createResponses(apiKey, {
        model,
        input: toolOutputs,
        tools,
        previousResponseId: responseId,
        signal,
        onDelta,
      });
    }

    if (exhaustedToolSteps) {
      throw new TurnLimitError("maxToolSteps", { maxToolSteps });
    }

    queue.push({
      type: "notification",
      ...makeAgentMessageCompletedNotification({
        threadId: args.threadId,
        turnId: args.turnId,
        itemId: agentItemId,
        text: accumulatedText.trim(),
      }),
    });

    queue.push({
      type: "notification",
      ...makeTurnCompletedNotification({
        threadId: args.threadId,
        turnId: args.turnId,
        status: "completed",
        error: null,
      }),
    });
  }

  private buildToolDefinitions(planMode: boolean): OpenAIResponsesToolDefinition[] {
    const tools: OpenAIResponsesToolDefinition[] = [
      {
        name: "exec_command",
        description: "Execute a shell command on the remote HPC workspace.",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            cmd: { type: "string", description: "Shell command to execute." },
            cwd: { type: "string", description: "Working directory (optional)." },
            timeoutMs: { type: "number", description: "Timeout in milliseconds (optional)." },
            env: {
              type: "object",
              description: "Environment variables (optional).",
              additionalProperties: { type: "string" },
            },
          },
          required: ["cmd"],
        },
      },
      {
        name: "apply_patch",
        description: "Apply a unified diff patch in the remote HPC workspace.",
        parameters: {
          type: "object",
          additionalProperties: false,
          properties: {
            patch: { type: "string", description: "Unified diff patch text." },
          },
          required: ["patch"],
        },
      },
    ];

    if (planMode) {
      tools.push(
        {
          name: "update_plan",
          description: "Update the current implementation plan progress.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              explanation: { type: "string" },
              plan: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    step: { type: "string" },
                    status: { type: "string", enum: ["pending", "inProgress", "completed"] },
                  },
                  required: ["step", "status"],
                },
              },
            },
            required: ["plan"],
          },
        },
        {
          name: "request_user_input",
          description: "Ask the user a question and wait for their response.",
          parameters: {
            type: "object",
            additionalProperties: false,
            properties: {
              questions: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    header: { type: "string" },
                    id: { type: "string" },
                    question: { type: "string" },
                    options: {
                      type: "array",
                      items: {
                        type: "object",
                        additionalProperties: false,
                        properties: {
                          label: { type: "string" },
                          description: { type: "string" },
                        },
                        required: ["label", "description"],
                      },
                    },
                  },
                  required: ["header", "id", "question", "options"],
                },
              },
            },
            required: ["questions"],
          },
        }
      );
    }

    return tools;
  }

  private async executeToolCall(args: {
    threadId: string;
    turnId: string;
    cwd: string;
    approvalPolicy: string;
    call: OpenAIResponsesToolCall;
    queue: AsyncPushQueue<EngineStreamEvent>;
    signal: AbortSignal;
  }): Promise<Record<string, unknown>> {
    const name = args.call.name.toLowerCase();
    if (name === "exec_command") {
      return await this.toolExecCommand(args);
    }
    if (name === "apply_patch") {
      return await this.toolApplyPatch(args);
    }
    if (name === "update_plan") {
      return await this.toolUpdatePlan(args);
    }
    if (name === "request_user_input") {
      return await this.toolRequestUserInput(args);
    }
    return { ok: false, error: `Unknown tool: ${args.call.name}` };
  }

  private async toolExecCommand(args: {
    threadId: string;
    turnId: string;
    cwd: string;
    approvalPolicy: string;
    call: OpenAIResponsesToolCall;
    queue: AsyncPushQueue<EngineStreamEvent>;
    signal: AbortSignal;
  }): Promise<Record<string, unknown>> {
    const cmd = normalizeNonEmptyString(args.call.arguments.cmd);
    if (!cmd) return { ok: false, error: "exec_command requires cmd" };
    const cwd = normalizeNonEmptyString(args.call.arguments.cwd) ?? args.cwd;
    const timeoutMs = normalizePositiveInteger(args.call.arguments.timeoutMs);
    const env = normalizeStringRecord(args.call.arguments.env);

    const itemId = `item_exec_${uuidv4()}`;
    const startedAt = Date.now();
    const itemStarted: ThreadItem = {
      type: "commandExecution",
      id: itemId,
      command: cmd,
      cwd,
      processId: null,
      status: "inProgress",
      commandActions: [],
      aggregatedOutput: null,
      exitCode: null,
      durationMs: null,
    };

    args.queue.push({
      type: "notification",
      method: "item/started",
      params: {
        threadId: args.threadId,
        turnId: args.turnId,
        item: itemStarted,
      },
    });

    const approvalPolicy = String(args.approvalPolicy ?? "").trim().toLowerCase();
    if (approvalPolicy !== "never") {
      const approvalRequest = makeCommandExecutionApprovalRequest({
        id: `apr_exec_${uuidv4()}`,
        threadId: args.threadId,
        turnId: args.turnId,
        itemId,
        reason: "Approve running this command on HPC?",
        command: cmd,
        cwd,
      });
      const approval = await this.awaitServerRequest<Record<string, unknown>>(
        args.queue,
        {
          method: approvalRequest.method,
          id: String(approvalRequest.id),
          params: approvalRequest.params,
        },
        args.signal
      );

      const decision = normalizeApprovalDecision(approval);
      if (decision === "cancel") {
        throw new AbortTurnError();
      }
      if (decision === "decline") {
        const completedItem = { ...itemStarted, status: "interrupted", aggregatedOutput: "Execution declined by user." };
        args.queue.push({
          type: "notification",
          method: "item/completed",
          params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
        });
        return { ok: false, declined: true };
      }
    }

    const command0 = "/bin/bash";
    let result: Record<string, unknown>;
    try {
      result = await this.awaitServerRequest<Record<string, unknown>>(
        args.queue,
        {
          method: "runtime/commandExecution/exec",
          id: `rt_exec_${uuidv4()}`,
          params: {
            threadId: args.threadId,
            turnId: args.turnId,
            itemId,
            command: [command0, "-c", cmd],
            cwd,
            ...(timeoutMs != null ? { timeoutMs } : {}),
            ...(env ? { env } : {}),
          },
        },
        args.signal
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const durationMs = Math.max(0, Date.now() - startedAt);
      const completedItem: ThreadItem = {
        ...itemStarted,
        status: "failed",
        aggregatedOutput: message,
        exitCode: null,
        durationMs,
      };
      args.queue.push({
        type: "notification",
        method: "item/completed",
        params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
      });
      throw new RuntimeRequestError(message, {
        engineName: this.name,
        method: "runtime/commandExecution/exec",
        cwd,
        command0,
      });
    }

    const ok = Boolean(result.ok ?? (result.exitCode === 0));
    const exitCode = normalizeNullableInteger(result.exitCode);
    const durationMs = normalizeNullableInteger(result.durationMs) ?? Math.max(0, Date.now() - startedAt);
    const stdout = normalizeNullableString(result.stdout);
    const stderr = normalizeNullableString(result.stderr);
    const aggregatedOutput = [stdout, stderr].filter(Boolean).join("");
    const processId = normalizeNonEmptyString(result.executionId) ?? null;
    const completedItem: ThreadItem = {
      ...itemStarted,
      processId,
      status: ok ? "completed" : "failed",
      aggregatedOutput: aggregatedOutput || null,
      exitCode,
      durationMs,
    };

    args.queue.push({
      type: "notification",
      method: "item/completed",
      params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
    });

    return {
      ok,
      exitCode,
      durationMs,
      stdout: stdout ?? "",
      stderr: stderr ?? "",
    };
  }

  private async toolApplyPatch(args: {
    threadId: string;
    turnId: string;
    cwd: string;
    approvalPolicy: string;
    call: OpenAIResponsesToolCall;
    queue: AsyncPushQueue<EngineStreamEvent>;
    signal: AbortSignal;
  }): Promise<Record<string, unknown>> {
    const patch = normalizeNonEmptyString(args.call.arguments.patch);
    if (!patch) return { ok: false, error: "apply_patch requires patch" };

    const itemId = `item_patch_${uuidv4()}`;
    const itemStarted: ThreadItem = {
      type: "fileChange",
      id: itemId,
      changes: [],
      status: "pending",
    };
    args.queue.push({
      type: "notification",
      method: "item/started",
      params: { threadId: args.threadId, turnId: args.turnId, item: itemStarted },
    });

    const approvalPolicy = String(args.approvalPolicy ?? "").trim().toLowerCase();
    if (approvalPolicy !== "never") {
      const approvalRequest = makeFileChangeApprovalRequest({
        id: `apr_patch_${uuidv4()}`,
        threadId: args.threadId,
        turnId: args.turnId,
        itemId,
        reason: "Approve applying this patch on HPC?",
      });
      const approval = await this.awaitServerRequest<Record<string, unknown>>(
        args.queue,
        {
          method: approvalRequest.method,
          id: String(approvalRequest.id),
          params: approvalRequest.params,
        },
        args.signal
      );

      const decision = normalizeApprovalDecision(approval);
      if (decision === "cancel") {
        throw new AbortTurnError();
      }
      if (decision === "decline") {
        const completedItem: ThreadItem = { ...itemStarted, status: "rejected" };
        args.queue.push({
          type: "notification",
          method: "item/completed",
          params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
        });
        return { ok: false, declined: true };
      }
    }

    let result: Record<string, unknown>;
    try {
      result = await this.awaitServerRequest<Record<string, unknown>>(
        args.queue,
        {
          method: "runtime/fileChange/applyPatch",
          id: `rt_patch_${uuidv4()}`,
          params: {
            threadId: args.threadId,
            turnId: args.turnId,
            itemId,
            patch,
          },
        },
        args.signal
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const completedItem: ThreadItem = { ...itemStarted, status: "failed" };
      args.queue.push({
        type: "notification",
        method: "item/completed",
        params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
      });
      throw new RuntimeRequestError(message, {
        engineName: this.name,
        method: "runtime/fileChange/applyPatch",
        cwd: null,
        command0: null,
      });
    }

    const applied = Boolean(result.applied ?? result.ok);
    const changedPaths = Array.isArray(result.changedPaths)
      ? result.changedPaths.map((p) => String(p)).filter(Boolean)
      : [];
    const diff = normalizeNullableStringTrimmed(result.diff) ?? patch;

    const changes = changedPaths.length > 0
      ? changedPaths.map((p) => ({
          path: p,
          kind: "update",
          diff: diffForSinglePath(diff, p) || diff,
        }))
      : [
          {
            path: "patch",
            kind: "update",
            diff,
          },
        ];

    const completedItem: ThreadItem = {
      type: "fileChange",
      id: itemId,
      changes,
      status: applied ? "applied" : "failed",
    };

    args.queue.push({
      type: "notification",
      method: "item/completed",
      params: { threadId: args.threadId, turnId: args.turnId, item: completedItem },
    });

    return {
      ok: applied,
      applied,
      changedPaths,
    };
  }

  private async toolUpdatePlan(args: {
    threadId: string;
    turnId: string;
    call: OpenAIResponsesToolCall;
    queue: AsyncPushQueue<EngineStreamEvent>;
  }): Promise<Record<string, unknown>> {
    const planRaw = Array.isArray(args.call.arguments.plan) ? args.call.arguments.plan : [];
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

    if (plan.length > 0) {
      args.queue.push({
        type: "notification",
        method: "turn/plan/updated",
        params: {
          threadId: args.threadId,
          turnId: args.turnId,
          explanation: normalizeNullableStringTrimmed(args.call.arguments.explanation),
          plan,
        },
      });
    }
    return { ok: true };
  }

  private async toolRequestUserInput(args: {
    threadId: string;
    turnId: string;
    call: OpenAIResponsesToolCall;
    queue: AsyncPushQueue<EngineStreamEvent>;
    signal: AbortSignal;
  }): Promise<Record<string, unknown>> {
    const questions = Array.isArray(args.call.arguments.questions) ? args.call.arguments.questions : [];
    const normalizedQuestions = questions
      .map((q) => {
        if (!q || typeof q !== "object" || Array.isArray(q)) return null;
        const row = q as Record<string, unknown>;
        const header = normalizeNonEmptyString(row.header);
        const id = normalizeNonEmptyString(row.id);
        const question = normalizeNonEmptyString(row.question);
        const optionsRaw = Array.isArray(row.options) ? row.options : [];
        const options = optionsRaw
          .map((o) => {
            if (!o || typeof o !== "object" || Array.isArray(o)) return null;
            const opt = o as Record<string, unknown>;
            const label = normalizeNonEmptyString(opt.label);
            const description = normalizeNonEmptyString(opt.description) ?? "";
            if (!label) return null;
            return { label, description };
          })
          .filter((o): o is { label: string; description: string } => o != null);
        if (!header || !id || !question) return null;
        return { header, id, question, options };
      })
      .filter((q): q is { header: string; id: string; question: string; options: Array<{ label: string; description: string }> } => q != null);

    if (normalizedQuestions.length === 0) {
      return { ok: false, error: "request_user_input requires questions" };
    }

    const response = await this.awaitServerRequest<Record<string, unknown>>(
      args.queue,
      {
        method: "item/tool/requestUserInput",
        id: `prompt_${uuidv4()}`,
        params: {
          threadId: args.threadId,
          turnId: args.turnId,
          itemId: `item_prompt_${uuidv4()}`,
          prompt: "",
          questions: normalizedQuestions,
        },
      },
      args.signal
    );

    return response ?? {};
  }

  private async createResponses(
    apiKey: string,
    args: {
      model: string;
      input: unknown;
      tools: OpenAIResponsesToolDefinition[];
      previousResponseId?: string;
      signal?: AbortSignal;
      onDelta?: (delta: string) => void;
    }
  ): Promise<OpenAIResponsesResponse> {
    const url = `${this.baseUrl}/v1/responses`;
    let streamedText = "";
    const emitDelta = (delta: string) => {
      if (!delta) return;
      streamedText += delta;
      args.onDelta?.(delta);
    };

    const baseBody: Record<string, unknown> = {
      model: args.model,
      input: args.input,
      tools: args.tools.map((tool) => ({
        type: "function",
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
      })),
      temperature: 0,
      stream: true,
    };
    if (args.previousResponseId) {
      baseBody.previous_response_id = args.previousResponseId;
    }

    const res = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(baseBody),
      signal: args.signal,
    });

    if (!res.ok) {
      const message = await safeReadText(res);
      throw new Error(`OpenAI responses failed (${res.status}): ${message}`);
    }

    const contentType = String(res.headers.get("content-type") ?? "").toLowerCase();
    const isEventStream = contentType.includes("text/event-stream");
    if (isEventStream && res.body) {
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let completed: OpenAIResponsesResponse | null = null;
      let failure: string | null = null;

      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        buffer += decoder.decode(chunk.value, { stream: true });

        let separator = findSseSeparator(buffer);
        while (separator) {
          const rawEvent = buffer.slice(0, separator.index);
          buffer = buffer.slice(separator.index + separator.length);
          separator = findSseSeparator(buffer);

          const data = extractSseData(rawEvent);
          if (!data) continue;
          if (data.trim() === "[DONE]") continue;

          let parsed: any;
          try {
            parsed = JSON.parse(data);
          } catch {
            continue;
          }

          const type = String(parsed?.type ?? "");
          if (type === "response.output_text.delta") {
            const delta = normalizeNonEmptyString(parsed?.delta);
            if (delta) emitDelta(delta);
            continue;
          }
          if (type === "response.failed") {
            failure = normalizeNonEmptyString(parsed?.error?.message)
              ?? normalizeNonEmptyString(parsed?.message)
              ?? data.slice(0, 800);
            continue;
          }
          if (type === "response.completed") {
            const response = parsed?.response ?? parsed;
            if (response && typeof response === "object") {
              completed = response as OpenAIResponsesResponse;
            }
            continue;
          }
        }
      }

      if (failure) {
        throw new Error(`OpenAI responses stream failed: ${failure}`);
      }
      if (!completed) {
        throw new Error("OpenAI responses SSE stream disconnected before completion.");
      }

      const finalText = extractResponseText(completed);
      if (finalText && finalText.length > streamedText.length && finalText.startsWith(streamedText)) {
        emitDelta(finalText.slice(streamedText.length));
      }
      return completed;
    }

    const parsed = (await res.json()) as OpenAIResponsesResponse;
    const text = extractResponseText(parsed);
    if (text) emitDelta(text);
    return parsed;
  }

  private async awaitServerRequest<T>(
    queue: AsyncPushQueue<EngineStreamEvent>,
    request: { method: string; id: string; params: Record<string, unknown> },
    signal: AbortSignal
  ): Promise<T> {
    const abortPromise = signal.aborted
      ? Promise.reject(new AbortTurnError())
      : new Promise<never>((_, reject) => {
          signal.addEventListener("abort", () => reject(new AbortTurnError()), { once: true });
        });

    const requestPromise = new Promise<T>((resolve, reject) => {
      queue.push({
        type: "serverRequest",
        id: request.id,
        method: request.method,
        params: request.params,
        respond: async (response) => {
          if (response.error) {
            reject(new Error(String(response.error.message ?? "server request failed")));
          } else {
            resolve((response.result as T) ?? ({} as T));
          }
        },
      });
    });

    return await Promise.race([requestPromise, abortPromise]);
  }

  private buildAdditionalDetailsForTurnError(err: unknown): string | null {
    const message = String(err instanceof Error ? err.message : err ?? "")
      .trim()
      .toLowerCase();
    if (!message) return null;
    if (err instanceof TurnLimitError) {
      const lines = [
        `engineName=${this.name}`,
        `limit=${err.limit}`,
        err.maxTurnMs != null ? `maxTurnMs=${err.maxTurnMs}` : null,
        err.elapsedMs != null ? `elapsedMs=${err.elapsedMs}` : null,
        err.maxToolSteps != null ? `maxToolSteps=${err.maxToolSteps}` : null,
        "Hint: The model may be stuck in a tool loop. Use turn/interrupt, then retry with a narrower request if needed.",
      ].filter((line): line is string => Boolean(line && line.trim()));
      return lines.join("\n");
    }
    if (err instanceof RuntimeRequestError) {
      const lines = [
        `engineName=${err.engineName}`,
        `method=${err.method}`,
        err.cwd ? `cwd=${err.cwd}` : null,
        err.command0 ? `command[0]=${err.command0}` : null,
      ].filter((line): line is string => Boolean(line && line.trim()));
      if (message.includes("no such file or directory") || message.includes("enoent")) {
        lines.push(
          "Hint: If Hub and HPC do not share a filesystem, use the epoch-hpc engine so exec/applyPatch run via the HPC bridge."
        );
      }
      return lines.join("\n");
    }
    if (message.includes("no such file or directory") || message.includes("enoent")) {
      return [
        `engineName=${this.name}`,
        "Hint: If Hub and HPC do not share a filesystem, use the epoch-hpc engine so exec/applyPatch run via the HPC bridge.",
      ].join("\n");
    }
    return null;
  }
}

function buildResponsesInput(args: {
  developerInstructions: string | null;
  historyTurns: Turn[];
  userInput: UserInput[];
}): Array<Record<string, unknown>> {
  const input: Array<Record<string, unknown>> = [];
  if (args.developerInstructions) {
    input.push({
      role: "developer",
      content: [{ type: "input_text", text: args.developerInstructions }],
    });
  }

  const history = buildConversationFromTurns(args.historyTurns);
  input.push(...history);

  const userText = flattenUserInputToText(args.userInput);
  if (userText) {
    input.push({
      role: "user",
      content: [{ type: "input_text", text: userText }],
    });
  }
  return input;
}

function buildConversationFromTurns(turns: Turn[]): Array<Record<string, unknown>> {
  const messages: Array<Record<string, unknown>> = [];

  for (const turn of turns) {
    for (const item of turn.items ?? []) {
      if (!item || typeof item !== "object") continue;
      const typed = item as ThreadItem;
      if (typed.type === "userMessage") {
        const text = flattenUserInputToText(Array.isArray((typed as any).content) ? (typed as any).content : []);
        if (text) {
          messages.push({ role: "user", content: [{ type: "input_text", text }] });
        }
        continue;
      }
      if (typed.type === "agentMessage" || typed.type === "plan") {
        const text = normalizeNonEmptyString((typed as any).text);
        if (text) {
          messages.push({ role: "assistant", content: [{ type: "output_text", text }] });
        }
        continue;
      }
      if (typed.type === "commandExecution") {
        const cmd = normalizeNonEmptyString((typed as any).command) ?? "";
        const cwd = normalizeNonEmptyString((typed as any).cwd) ?? "";
        const exitCode = (typed as any).exitCode;
        const output = normalizeNonEmptyString((typed as any).aggregatedOutput) ?? "";
        const summary = [
          "[tool:exec_command]",
          cmd ? `cmd: ${cmd}` : null,
          cwd ? `cwd: ${cwd}` : null,
          exitCode != null ? `exitCode: ${String(exitCode)}` : null,
          output ? `output:\n${output.slice(0, 3_000)}` : null,
        ]
          .filter(Boolean)
          .join("\n");
        messages.push({ role: "developer", content: [{ type: "input_text", text: summary }] });
        continue;
      }
      if (typed.type === "fileChange") {
        const changes = Array.isArray((typed as any).changes) ? (typed as any).changes : [];
        const diffs = changes
          .map((c: any) => normalizeNonEmptyString(c?.diff))
          .filter(Boolean)
          .join("\n");
        const summary = diffs
          ? `[tool:apply_patch]\n${diffs.slice(0, 6_000)}`
          : "[tool:apply_patch] (no diff recorded)";
        messages.push({ role: "developer", content: [{ type: "input_text", text: summary }] });
      }
    }
  }

  return messages;
}

function extractResponseText(response: OpenAIResponsesResponse): string {
  if (typeof response.output_text === "string" && response.output_text.trim()) {
    return response.output_text;
  }

  let text = "";
  for (const output of response.output ?? []) {
    if (!output || typeof output !== "object") continue;
    const type = String((output as any).type ?? "");
    if (type !== "message") continue;
    const content = Array.isArray((output as any).content) ? (output as any).content : [];
    for (const entry of content) {
      if (!entry || typeof entry !== "object") continue;
      if (String((entry as any).type ?? "") !== "output_text") continue;
      const part = String((entry as any).text ?? "");
      if (part) {
        text += part;
      }
    }
  }
  return text;
}

function extractToolCalls(response: OpenAIResponsesResponse): OpenAIResponsesToolCall[] {
  const calls: OpenAIResponsesToolCall[] = [];
  const output = Array.isArray(response.output) ? response.output : [];

  for (const entry of output) {
    if (!entry || typeof entry !== "object") continue;
    const type = String((entry as any).type ?? "").toLowerCase();
    if (type !== "function_call" && type !== "tool_call") continue;

    const name =
      normalizeNonEmptyString((entry as any).name)
      ?? normalizeNonEmptyString((entry as any).tool)
      ?? normalizeNonEmptyString((entry as any).function?.name);
    const callId =
      normalizeNonEmptyString((entry as any).call_id)
      ?? normalizeNonEmptyString((entry as any).tool_call_id)
      ?? normalizeNonEmptyString((entry as any).id)
      ?? `call_${uuidv4()}`;
    if (!name) continue;

    const argsRaw =
      (entry as any).arguments
      ?? (entry as any).args
      ?? (entry as any).function?.arguments;
    const parsedArgs = parseJsonObjectOrEmpty(argsRaw);
    calls.push({ callId, name, arguments: parsedArgs });
  }

  return calls;
}

function parseJsonObjectOrEmpty(raw: unknown): Record<string, unknown> {
  if (!raw) return {};
  if (typeof raw === "object" && !Array.isArray(raw)) return raw as Record<string, unknown>;
  if (typeof raw !== "string") return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    return parsed as Record<string, unknown>;
  } catch {
    return {};
  }
}

function normalizeApprovalDecision(raw: Record<string, unknown>): "accept" | "decline" | "cancel" {
  const decision = raw?.decision;
  if (typeof decision === "string") {
    const d = decision.trim().toLowerCase();
    if (d === "decline") return "decline";
    if (d === "cancel") return "cancel";
    return "accept";
  }
  if (decision && typeof decision === "object" && !Array.isArray(decision)) {
    const key = Object.keys(decision)[0] ?? "";
    if (key.toLowerCase().includes("accept")) return "accept";
  }
  return "accept";
}

function normalizePlanStatus(raw: unknown): "pending" | "inProgress" | "completed" | null {
  const value = normalizeNonEmptyString(raw);
  if (!value) return null;
  const compact = value.trim().toLowerCase();
  if (compact === "pending") return "pending";
  if (compact === "inprogress" || compact === "in_progress") return "inProgress";
  if (compact === "completed") return "completed";
  return null;
}

function normalizeStringRecord(raw: unknown): Record<string, string> | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  return Object.fromEntries(Object.entries(obj).map(([k, v]) => [String(k), String(v ?? "")]));
}

function normalizePositiveInteger(raw: unknown): number | null {
  const n = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(n)) return null;
  const v = Math.floor(n);
  return v > 0 ? v : null;
}

function normalizeNullableInteger(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw)) return Math.floor(raw);
  if (typeof raw === "string" && raw.trim()) {
    const parsed = Number(raw);
    if (Number.isFinite(parsed)) return Math.floor(parsed);
  }
  return null;
}

function normalizeNullableString(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw !== "string") return null;
  return raw;
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeNullableStringTrimmed(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function findSseSeparator(buffer: string): { index: number; length: number } | null {
  const lfIndex = buffer.indexOf("\n\n");
  const crlfIndex = buffer.indexOf("\r\n\r\n");
  if (lfIndex === -1 && crlfIndex === -1) return null;
  if (lfIndex === -1) return { index: crlfIndex, length: 4 };
  if (crlfIndex === -1) return { index: lfIndex, length: 2 };
  return lfIndex < crlfIndex ? { index: lfIndex, length: 2 } : { index: crlfIndex, length: 4 };
}

function extractSseData(rawEvent: string): string | null {
  if (!rawEvent.trim()) return null;
  const dataLines: string[] = [];
  for (const line of rawEvent.split(/\r?\n/)) {
    if (line.startsWith("data:")) {
      dataLines.push(line.slice("data:".length).trimStart());
    }
  }
  if (dataLines.length === 0) return null;
  return dataLines.join("\n");
}

async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  mapper: (item: T, index: number) => Promise<R>
): Promise<R[]> {
  const bounded = Math.max(1, Math.floor(concurrency));
  const results = new Array<R>(items.length);
  let nextIndex = 0;
  const workers = Array.from({ length: Math.min(bounded, items.length) }, async () => {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) return;
      results[index] = await mapper(items[index], index);
    }
  });
  await Promise.all(workers);
  return results;
}

async function safeReadText(res: Response): Promise<string> {
  try {
    const text = await res.text();
    return text.slice(0, 800);
  } catch {
    return "unknown error";
  }
}

function diffForSinglePath(fullDiff: string, filePath: string): string {
  if (!fullDiff.trim()) return "";
  const normalized = filePath.replaceAll("\\", "/");
  const sections = fullDiff.split(/^diff --git /m);
  const matches = sections.filter((section) => section.includes(` a/${normalized} `) || section.includes(` b/${normalized}`));
  if (matches.length === 0) return "";
  return matches.map((section) => (section.startsWith("diff --git ") ? section : `diff --git ${section}`)).join("\n");
}
