import { v4 as uuidv4 } from "uuid";

import { buildProjectFileContextStream } from "../../indexing/projectIndexing.js";
import type { CodexEngineRegistry } from "../engine_registry.js";
import type { EngineStartTurnResult, EngineStreamEvent } from "../engines/types.js";
import type { CodexRepository } from "../repository.js";
import { nowUnixSeconds, type ThreadItem, type Turn, type UserInput } from "../types.js";
import { maybePersistThreadFromResponse, parseThreadSettings } from "./thread.js";

export type TurnHandlerContext = {
  repository: CodexRepository;
  engines: CodexEngineRegistry;
};

export type PreparedTurnStart = {
  threadId: string;
  turnId: string;
  turn: Turn;
  events: AsyncIterable<EngineStreamEvent>;
  preludeNotifications: Array<{ method: string; params: Record<string, unknown> }>;
};

export async function handleTurnStart(
  ctx: TurnHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<PreparedTurnStart> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  let threadId = normalizeNonEmptyString(params.threadId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  if (!threadId && sessionId) {
    const rows = await ctx.repository.query<any>(
      `SELECT codex_thread_id
       FROM sessions
       WHERE id=$1
       LIMIT 1`,
      [sessionId]
    );
    threadId = normalizeNonEmptyString(rows[0]?.codex_thread_id);
  }
  if (!threadId) {
    throw new Error("Missing threadId");
  }

  let threadRecord = await ctx.repository.getThreadRecord(threadId);
  if (!threadRecord) {
    throw new Error("Thread not found");
  }

  const threadSnapshot = await ctx.repository.readThread(threadId, true);
  if (!threadSnapshot) {
    throw new Error("Thread not found");
  }
  let historyTurns = threadSnapshot.turns;

  let settings = parseThreadSettings(threadRecord.statusJson, threadSnapshot);
  const modelOverride = normalizeNonEmptyString(params.model);
  const approvalPolicyOverride = normalizeNonEmptyString(params.approvalPolicy);
  const input = normalizeUserInputList(params.input);
  let engineInput = await buildTurnInputWithProjectContext(ctx.repository, threadRecord.projectId, input);
  let engine = await ctx.engines.getEngine(threadRecord.engine);

  // Codex passthrough engine controls its own item lifecycle and notifications.
  if (threadRecord.engine === "codex-app-server") {
    if (!isValidCodexAppServerThreadId(threadId)) {
      if (!engine.threadStart) {
        throw new Error("Codex app-server engine does not support thread/start.");
      }
      const responseHistory = buildResponseHistoryFromTurns(historyTurns);
      const sandboxMode = toCodexSandboxMode(settings.sandbox);

      const repaired = await engine.threadStart({
        cwd: settings.cwd,
        modelProvider: settings.modelProvider,
        ...(modelOverride ?? settings.model ? { model: modelOverride ?? settings.model } : {}),
        approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
        ...(sandboxMode ? { sandbox: sandboxMode } : {}),
      });
      const repairedThreadRaw = (repaired.thread ?? null) as Record<string, unknown> | null;
      const repairedThreadId = normalizeNonEmptyString(repairedThreadRaw?.id);
      if (!repairedThreadId) {
        throw new Error("Codex app-server did not return a replacement thread id.");
      }

      let effectiveThreadRaw = repairedThreadRaw;
      let effectiveThreadId = repairedThreadId;
      const repairedCwd = normalizeNonEmptyString(repairedThreadRaw?.cwd) ?? settings.cwd;
      const repairedModelProvider = normalizeNonEmptyString(repairedThreadRaw?.modelProvider) ?? settings.modelProvider;
      const repairedModelId = modelOverride ?? settings.model;
      const repairedCreatedAt = Number(repairedThreadRaw?.createdAt ?? nowUnixSeconds());
      const repairedPreview = normalizeNonEmptyString(repairedThreadRaw?.preview) ?? "";
      const repairedSettings = {
        ...settings,
        cwd: repairedCwd,
        modelProvider: repairedModelProvider,
        model: repairedModelId,
      };

      if (engine.threadResume && responseHistory.length > 0) {
        try {
          const resumed = await engine.threadResume({
            threadId: repairedThreadId,
            history: responseHistory,
            cwd: repairedCwd,
            modelProvider: repairedModelProvider,
            ...(repairedModelId ? { model: repairedModelId } : {}),
            approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
            ...(sandboxMode ? { sandbox: sandboxMode } : {}),
          });
          await maybePersistThreadFromResponse(ctx.repository, resumed, threadRecord.engine);
          const resumedThreadRaw = (resumed.thread ?? null) as Record<string, unknown> | null;
          const resumedThreadId = normalizeNonEmptyString(resumedThreadRaw?.id);
          if (resumedThreadId) {
            effectiveThreadId = resumedThreadId;
            effectiveThreadRaw = resumedThreadRaw;
          }
        } catch {
          // History resume is best effort for repaired threads.
        }
      }

      const effectiveCwd = normalizeNonEmptyString(effectiveThreadRaw?.cwd) ?? repairedCwd;
      const effectiveModelProvider = normalizeNonEmptyString(effectiveThreadRaw?.modelProvider) ?? repairedModelProvider;
      const effectiveCreatedAt = Number(effectiveThreadRaw?.createdAt ?? repairedCreatedAt);
      const effectivePreview = normalizeNonEmptyString(effectiveThreadRaw?.preview) ?? repairedPreview;

      const existingRepaired = await ctx.repository.getThreadRecord(effectiveThreadId);
      if (!existingRepaired) {
        await ctx.repository.createThread({
          id: effectiveThreadId,
          projectId: threadRecord.projectId,
          cwd: effectiveCwd,
          modelProvider: effectiveModelProvider,
          modelId: repairedModelId,
          preview: effectivePreview,
          statusJson: JSON.stringify(repairedSettings),
          engine: threadRecord.engine,
          createdAt: effectiveCreatedAt,
        });
      } else {
        await ctx.repository.updateThread({
          id: effectiveThreadId,
          cwd: effectiveCwd,
          modelProvider: effectiveModelProvider,
          modelId: repairedModelId,
          preview: effectivePreview,
          statusJson: JSON.stringify(repairedSettings),
          engine: threadRecord.engine,
        });
      }

      const mappedSession = await ctx.repository.findSessionByThread(threadId);
      if (mappedSession) {
        await ctx.repository.assignThreadToSession({ threadId, sessionId: null });
        await ctx.repository.assignThreadToSession({ threadId: effectiveThreadId, sessionId: mappedSession.sessionId });
        await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
          effectiveThreadId,
          new Date().toISOString(),
          mappedSession.sessionId,
        ]);
      } else if (sessionId) {
        await ctx.repository.assignThreadToSession({ threadId, sessionId: null });
        await ctx.repository.assignThreadToSession({ threadId: effectiveThreadId, sessionId });
        await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
          effectiveThreadId,
          new Date().toISOString(),
          sessionId,
        ]);
      }

      threadId = effectiveThreadId;
      threadRecord = (await ctx.repository.getThreadRecord(threadId)) ?? threadRecord;
      settings = repairedSettings;
      historyTurns = (await ctx.repository.readThread(threadId, true))?.turns ?? historyTurns;
      engineInput = await buildTurnInputWithProjectContext(ctx.repository, threadRecord.projectId, input);
      engine = await ctx.engines.getEngine(threadRecord.engine);
    }

    const provisionalTurnId = `turn_${uuidv4()}`;
    const started = await engine.startTurn({
      threadId,
      turnId: provisionalTurnId,
      input: engineInput,
      historyTurns,
      cwd: settings.cwd,
      model: modelOverride ?? settings.model,
      modelProvider: settings.modelProvider,
      approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
    });

    const turnId = started.turn.id;

    return {
      threadId,
      turnId,
      turn: started.turn,
      events: started.events,
      preludeNotifications: [],
    };
  }

  const turnId = `turn_${uuidv4()}`;
  await ctx.repository.createTurn({
    id: turnId,
    threadId,
    status: "inProgress",
    error: null,
    createdAt: nowUnixSeconds(),
  });

  const userMessageItemId = `item_${uuidv4()}`;
  const userMessageItem = {
    type: "userMessage",
    id: userMessageItemId,
    content: input,
  } as const;

  const preludeNotifications = [
    {
      method: "turn/started",
      params: {
        threadId,
        turn: {
          id: turnId,
          items: [],
          status: "inProgress",
          error: null,
        },
      },
    },
    {
      method: "item/started",
      params: {
        threadId,
        turnId,
        item: userMessageItem,
      },
    },
    {
      method: "item/completed",
      params: {
        threadId,
        turnId,
        item: userMessageItem,
      },
    },
  ];

  await ctx.repository.upsertItem({
    id: userMessageItem.id,
    threadId,
    turnId,
    type: userMessageItem.type,
    payload: userMessageItem,
  });

  const started: EngineStartTurnResult = await engine.startTurn({
    threadId,
    turnId,
    input: engineInput,
    historyTurns,
    cwd: settings.cwd,
    model: modelOverride ?? settings.model,
    modelProvider: settings.modelProvider,
    approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
  });

  return {
    threadId,
    turnId,
    turn: started.turn,
    events: started.events,
    preludeNotifications,
  };
}

const CODEX_APP_SERVER_THREAD_ID_RE = /^(?:urn:uuid:)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function isValidCodexAppServerThreadId(threadId: string): boolean {
  return CODEX_APP_SERVER_THREAD_ID_RE.test(threadId.trim());
}

function toCodexSandboxMode(raw: unknown): "read-only" | "workspace-write" | "danger-full-access" | null {
  if (typeof raw === "string") {
    const normalized = raw.trim().toLowerCase();
    if (normalized === "read-only" || normalized === "readonly" || normalized === "read_only") return "read-only";
    if (normalized === "workspace-write" || normalized === "workspacewrite" || normalized === "workspace_write") {
      return "workspace-write";
    }
    if (
      normalized === "danger-full-access" ||
      normalized === "dangerfullaccess" ||
      normalized === "danger_full_access"
    ) {
      return "danger-full-access";
    }
    return null;
  }

  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  return toCodexSandboxMode(normalizeNonEmptyString(obj.mode) ?? normalizeNonEmptyString(obj.type) ?? null);
}

const PROJECT_CONTEXT_MARKER = "[LABOS_PROJECT_CONTEXT]";
const MAX_SNIPPET_CHARS = 2_200;

async function buildTurnInputWithProjectContext(repository: CodexRepository, projectId: string | null, input: UserInput[]): Promise<UserInput[]> {
  if (!projectId || !input.length) return input;

  const promptText = input
    .map((part) => (part.type === "text" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();

  if (!promptText || promptText.includes(PROJECT_CONTEXT_MARKER)) return input;

  let stream;
  try {
    stream = await buildProjectFileContextStream(repository.dbPool(), projectId, promptText, {
      getOpenAIApiKey: async () => normalizeNonEmptyString(process.env.OPENAI_API_KEY) ?? undefined,
      fileLimit: 40,
      snippetLimit: 6,
    });
  } catch {
    return input;
  }

  if (!stream.snippets.length) {
    return input;
  }

  const snippets = [...stream.snippets]
    .sort((a, b) => b.score - a.score)
    .map((snippet, index) => {
      const content = snippet.content.replace(/\s+/g, " ").trim().slice(0, MAX_SNIPPET_CHARS);
      return `(${index + 1}) ${snippet.path}#${snippet.chunkIndex}\n${content}`;
    });

  const contextBlock = `${PROJECT_CONTEXT_MARKER}
Use these indexed project snippets as additional context:
${snippets.join("\n\n")}`;

  const next = input.map((part) => ({ ...part }));
  const firstTextIndex = next.findIndex((part) => part.type === "text");
  if (firstTextIndex >= 0) {
    const firstText = next[firstTextIndex] as Extract<UserInput, { type: "text" }>;
    next[firstTextIndex] = {
      ...firstText,
      text: `${contextBlock}\n\nUser request:\n${firstText.text}`,
    };
  } else {
    next.unshift({
      type: "text",
      text: `${contextBlock}\n\nUser request:\n${promptText}`,
      text_elements: [],
    });
  }

  return next;
}

export async function handleTurnInterrupt(
  ctx: TurnHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, never>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  let threadId = normalizeNonEmptyString(params.threadId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  if (!threadId && sessionId) {
    const rows = await ctx.repository.query<any>(
      `SELECT codex_thread_id
       FROM sessions
       WHERE id=$1
       LIMIT 1`,
      [sessionId]
    );
    threadId = normalizeNonEmptyString(rows[0]?.codex_thread_id);
  }
  const turnId = normalizeNonEmptyString(params.turnId);
  if (!threadId || !turnId) {
    throw new Error("Missing threadId or turnId");
  }

  const threadRecord = await ctx.repository.getThreadRecord(threadId);
  if (!threadRecord) {
    throw new Error("Thread not found");
  }

  const engine = await ctx.engines.getEngine(threadRecord.engine);
  await engine.interruptTurn({ threadId, turnId });

  await ctx.repository.updateTurn({
    id: turnId,
    status: "interrupted",
    completedAt: nowUnixSeconds(),
    touchThreadId: threadId,
  });

  return {};
}

function normalizeUserInputList(raw: unknown): UserInput[] {
  if (!Array.isArray(raw)) {
    return [
      {
        type: "text",
        text: "",
        text_elements: [],
      },
    ];
  }

  const normalized = raw
    .map((entry) => normalizeUserInput(entry))
    .filter((entry): entry is UserInput => entry != null);

  if (normalized.length === 0) {
    return [
      {
        type: "text",
        text: "",
        text_elements: [],
      },
    ];
  }

  return normalized;
}

function normalizeUserInput(raw: unknown): UserInput | null {
  if (!raw || typeof raw !== "object") return null;
  const entry = raw as Record<string, unknown>;
  const type = normalizeNonEmptyString(entry.type);
  if (!type) return null;

  if (type === "text") {
    return {
      type: "text",
      text: String(entry.text ?? ""),
      text_elements: Array.isArray(entry.text_elements)
        ? entry.text_elements.filter((part): part is Record<string, unknown> => Boolean(part && typeof part === "object"))
        : [],
    };
  }
  if (type === "image") {
    return {
      type: "image",
      url: String(entry.url ?? ""),
    };
  }
  if (type === "localImage") {
    return {
      type: "localImage",
      path: String(entry.path ?? ""),
    };
  }
  if (type === "skill") {
    return {
      type: "skill",
      name: String(entry.name ?? ""),
      path: String(entry.path ?? ""),
    };
  }
  if (type === "mention") {
    return {
      type: "mention",
      name: String(entry.name ?? ""),
      path: String(entry.path ?? ""),
    };
  }

  return null;
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function buildResponseHistoryFromTurns(turns: Turn[]): Array<Record<string, unknown>> {
  const history: Array<Record<string, unknown>> = [];
  for (const turn of turns) {
    for (const item of turn.items) {
      appendResponseHistoryFromItem(history, item);
    }
  }
  return history;
}

function appendResponseHistoryFromItem(history: Array<Record<string, unknown>>, item: ThreadItem) {
  if (item.type === "userMessage") {
    const content: Array<Record<string, unknown>> = [];
    for (const part of item.content) {
      if (part.type === "text") {
        const text = String(part.text ?? "").trim();
        if (text) {
          content.push({ type: "input_text", text });
        }
        continue;
      }
      if (part.type === "image") {
        const imageUrl = String(part.url ?? "").trim();
        if (imageUrl) {
          content.push({ type: "input_image", image_url: imageUrl });
        }
        continue;
      }
      if (part.type === "localImage") {
        const localPath = String(part.path ?? "").trim();
        if (localPath) {
          const imageUrl = localPath.startsWith("file://") ? localPath : `file://${localPath}`;
          content.push({ type: "input_image", image_url: imageUrl });
        }
      }
    }
    if (content.length > 0) {
      history.push({
        type: "message",
        role: "user",
        content,
        end_turn: true,
      });
    }
    return;
  }

  if (item.type === "agentMessage" || item.type === "plan") {
    const text = String(item.text ?? "").trim();
    if (!text) return;
    history.push({
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text }],
      end_turn: true,
    });
  }
}
