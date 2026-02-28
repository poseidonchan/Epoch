import { v4 as uuidv4 } from "uuid";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { buildProjectFileContextStream } from "../../indexing/projectIndexing.js";
import { resolveHubProvider } from "../../model.js";
import { loadOpenAIApiKeyFromStateDir } from "../../openai_settings.js";
import type { CodexEngineRegistry } from "../engine_registry.js";
import type { EngineStartTurnResult, EngineStreamEvent } from "../engines/types.js";
import type { CodexRepository } from "../repository.js";
import { nowUnixSeconds, type ThreadItem, type Turn, type UserInput } from "../types.js";
import { maybePersistThreadFromResponse, parseThreadSettings } from "./thread.js";

const PLAN_MODE_DEVELOPER_INSTRUCTIONS = [
  "Plan mode is active for this turn.",
  "Focus on planning and clarifying questions before implementation.",
  "Use request_user_input when user decisions are needed (prefer it over plain-text questions).",
  "Ask one question at a time when using request_user_input; prefer a single question per prompt unless strictly necessary.",
  "If the user indicates they want to stop or cancel (e.g. 'stop', 'stop the test', 'cancel', 'quit'), stop immediately and do not produce a <proposed_plan> block. If unclear, ask a single request_user_input confirmation (Continue vs Stop).",
  "When you present the final plan, wrap it in a <proposed_plan>...</proposed_plan> block with the opening and closing tags on their own lines; put the plan content between them in Markdown.",
  "Do not ask whether to implement the plan in plain text; the app will prompt the user after the plan.",
  "If asked whether plan mode is active, answer YES.",
  "Do not claim or imply that default mode is active while this mode is active.",
].join(" ");

export type TurnHandlerContext = {
  repository: CodexRepository;
  engines: CodexEngineRegistry;
};

export type PreparedTurnStart = {
  threadId: string;
  turnId: string;
  turn: Turn;
  planMode: boolean;
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
  const normalizedCwd = await normalizeThreadCwdForProject(ctx.repository, threadRecord.projectId, settings.cwd);
  if (normalizedCwd !== settings.cwd) {
    const nextStatusJson = withUpdatedThreadStatusCwd(threadRecord.statusJson, normalizedCwd, settings);
    await ctx.repository.updateThread({
      id: threadId,
      cwd: normalizedCwd,
      statusJson: nextStatusJson,
      updatedAt: nowUnixSeconds(),
    });
    threadRecord = {
      ...threadRecord,
      cwd: normalizedCwd,
      statusJson: nextStatusJson,
    };
    settings = {
      ...settings,
      cwd: normalizedCwd,
    };
  }
  const modelOverride = normalizeNonEmptyString(params.model);
  const planMode = normalizePlanMode(params.planMode);
  const approvalPolicyOverride = normalizeNonEmptyString(params.approvalPolicy);
  const input = await normalizeUserInputList(ctx.repository, threadRecord.projectId, threadId, params.input);
  let projectContext = await buildTurnInputWithProjectContext(ctx.repository, threadRecord.projectId, input);
  let engineInput = projectContext.input;
  let projectContextDeveloperInstructions = projectContext.developerInstructions;
  if (threadRecord.engine !== "codex-app-server") {
    await ctx.repository.updateThread({
      id: threadId,
      engine: "codex-app-server",
      updatedAt: nowUnixSeconds(),
    });
    threadRecord = {
      ...threadRecord,
      engine: "codex-app-server",
    };
  }
  let engine = await ctx.engines.getEngine("codex-app-server");
  let shouldInjectHistoryFallbackContext = readThreadSyncState(threadRecord.statusJson) === "needsRemoteHydration";

  const repairCodexThreadMapping = async () => {
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

    let resumedHistory = false;
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
        await maybePersistThreadFromResponse(ctx.repository, resumed, "codex-app-server");
        const resumedThreadRaw = (resumed.thread ?? null) as Record<string, unknown> | null;
        const resumedThreadId = normalizeNonEmptyString(resumedThreadRaw?.id);
        if (resumedThreadId) {
          effectiveThreadId = resumedThreadId;
          effectiveThreadRaw = resumedThreadRaw;
          resumedHistory = true;
        }
      } catch {
        resumedHistory = false;
      }
    }

    if (!engine.threadResume && responseHistory.length > 0) {
      resumedHistory = false;
    }

    if (responseHistory.length > 0 && !resumedHistory) {
      shouldInjectHistoryFallbackContext = true;
    } else if (resumedHistory) {
      shouldInjectHistoryFallbackContext = false;
    }

    const effectiveCwd = normalizeNonEmptyString(effectiveThreadRaw?.cwd) ?? repairedCwd;
    const effectiveModelProvider = normalizeNonEmptyString(effectiveThreadRaw?.modelProvider) ?? repairedModelProvider;
    const effectiveCreatedAt = Number(effectiveThreadRaw?.createdAt ?? repairedCreatedAt);
    const effectivePreview = normalizeNonEmptyString(effectiveThreadRaw?.preview) ?? repairedPreview;

    const existingRepaired = await ctx.repository.getThreadRecord(effectiveThreadId);
    if (!existingRepaired) {
      await ctx.repository.createThread({
        id: effectiveThreadId,
        projectId: threadRecord?.projectId ?? null,
        cwd: effectiveCwd,
        modelProvider: effectiveModelProvider,
        modelId: repairedModelId,
        preview: effectivePreview,
        statusJson: applyThreadSyncState(
          JSON.stringify(repairedSettings),
          shouldInjectHistoryFallbackContext ? "needsRemoteHydration" : "ready"
        ),
        engine: "codex-app-server",
        createdAt: effectiveCreatedAt,
      });
    } else {
      await ctx.repository.updateThread({
        id: effectiveThreadId,
        cwd: effectiveCwd,
        modelProvider: effectiveModelProvider,
        modelId: repairedModelId,
        preview: effectivePreview,
        statusJson: applyThreadSyncState(
          JSON.stringify(repairedSettings),
          shouldInjectHistoryFallbackContext ? "needsRemoteHydration" : "ready"
        ),
        engine: "codex-app-server",
      });
    }

    const previousThreadId = String(threadId);
    const mappedSession = await ctx.repository.findSessionByThread(previousThreadId);
    if (mappedSession) {
      await ctx.repository.assignThreadToSession({ threadId: previousThreadId, sessionId: null });
      await ctx.repository.assignThreadToSession({ threadId: effectiveThreadId, sessionId: mappedSession.sessionId });
      await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
        effectiveThreadId,
        new Date().toISOString(),
        mappedSession.sessionId,
      ]);
    } else if (sessionId) {
      await ctx.repository.assignThreadToSession({ threadId: previousThreadId, sessionId: null });
      await ctx.repository.assignThreadToSession({ threadId: effectiveThreadId, sessionId });
      await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
        effectiveThreadId,
        new Date().toISOString(),
        sessionId,
      ]);
    }

    threadId = effectiveThreadId;
    threadRecord = (await ctx.repository.getThreadRecord(threadId)) ?? threadRecord;
    settings = {
      ...repairedSettings,
      cwd: effectiveCwd,
      modelProvider: effectiveModelProvider,
    };
    historyTurns = (await ctx.repository.readThread(threadId, true))?.turns ?? historyTurns;
    projectContext = await buildTurnInputWithProjectContext(ctx.repository, threadRecord?.projectId ?? null, input);
    engineInput = projectContext.input;
    projectContextDeveloperInstructions = projectContext.developerInstructions;
    engine = await ctx.engines.getEngine("codex-app-server");
  };

  if (!isValidCodexAppServerThreadId(threadId)) {
    await repairCodexThreadMapping();
  }

  if (readThreadSyncState(threadRecord?.statusJson) === "needsRemoteHydration") {
    await repairCodexThreadMapping();
  }

  const historyFallbackDeveloperInstructions = shouldInjectHistoryFallbackContext
    ? injectHistoryFallbackContext(engineInput, historyTurns)
    : null;
  const contextDeveloperInstructions = [projectContextDeveloperInstructions, historyFallbackDeveloperInstructions]
    .filter((value): value is string => Boolean(value && value.trim()))
    .join("\n\n");

  const provisionalTurnId = `turn_${uuidv4()}`;
  let started: EngineStartTurnResult;
  const providerDefaults = resolveHubProvider(null);
  const effectiveModel = modelOverride ?? settings.model ?? providerDefaults.defaultModelId ?? null;
  const collaborationMode = buildCollaborationMode(planMode, effectiveModel, contextDeveloperInstructions);
  try {
    started = await engine.startTurn({
      threadId,
      turnId: provisionalTurnId,
      input: engineInput,
      historyTurns,
      cwd: settings.cwd,
      model: effectiveModel,
      modelProvider: settings.modelProvider,
      approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
      collaborationMode,
      sandboxPolicy: toCodexSandboxParam(injectWorkspaceRoots(settings.sandbox, settings.cwd)),
    });
  } catch (err) {
    if (!isLikelyCodexMissingThreadError(err)) {
      throw err;
    }

    await repairCodexThreadMapping();
    const repairedHistoryFallbackDeveloperInstructions = shouldInjectHistoryFallbackContext
      ? injectHistoryFallbackContext(engineInput, historyTurns)
      : null;
    const repairedContextDeveloperInstructions = [
      projectContextDeveloperInstructions,
      repairedHistoryFallbackDeveloperInstructions,
    ]
      .filter((value): value is string => Boolean(value && value.trim()))
      .join("\n\n");
    const repairedProviderDefaults = resolveHubProvider(null);
    const repairedEffectiveModel = modelOverride ?? settings.model ?? repairedProviderDefaults.defaultModelId ?? null;
    const repairedCollaborationMode = buildCollaborationMode(
      planMode,
      repairedEffectiveModel,
      repairedContextDeveloperInstructions
    );
    started = await engine.startTurn({
      threadId,
      turnId: provisionalTurnId,
      input: engineInput,
      historyTurns,
      cwd: settings.cwd,
      model: repairedEffectiveModel,
      modelProvider: settings.modelProvider,
      approvalPolicy: approvalPolicyOverride ?? settings.approvalPolicy,
      collaborationMode: repairedCollaborationMode,
      sandboxPolicy: toCodexSandboxParam(injectWorkspaceRoots(settings.sandbox, settings.cwd)),
    });
  }

  const turnId = started.turn.id;

  return {
    threadId,
    turnId,
    turn: started.turn,
    planMode,
    events: started.events,
    preludeNotifications: [],
  };
}

const CODEX_APP_SERVER_THREAD_ID_RE = /^(?:urn:uuid:)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function isValidCodexAppServerThreadId(threadId: string): boolean {
  return CODEX_APP_SERVER_THREAD_ID_RE.test(threadId.trim());
}

function isLikelyCodexMissingThreadError(err: unknown): boolean {
  const message = String(err instanceof Error ? err.message : err ?? "")
    .trim()
    .toLowerCase();
  if (!message) return false;
  return (
    (message.includes("thread") && message.includes("not found")) ||
    message.includes("unknown thread") ||
    message.includes("no such thread") ||
    message.includes("missing thread")
  );
}

function readThreadSyncState(rawStatusJson: string | null | undefined): "ready" | "needsRemoteHydration" | null {
  if (!rawStatusJson) return null;
  try {
    const parsed = JSON.parse(rawStatusJson);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const value = normalizeNonEmptyString((parsed as Record<string, unknown>).syncState);
    if (value === "ready") return "ready";
    if (value === "needsRemoteHydration") return "needsRemoteHydration";
    return null;
  } catch {
    return null;
  }
}

function applyThreadSyncState(
  rawStatusJson: string | null | undefined,
  syncState: "ready" | "needsRemoteHydration"
): string {
  const base = (() => {
    if (!rawStatusJson) return {} as Record<string, unknown>;
    try {
      const parsed = JSON.parse(rawStatusJson);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {} as Record<string, unknown>;
      return parsed as Record<string, unknown>;
    } catch {
      return {} as Record<string, unknown>;
    }
  })();
  return JSON.stringify({
    ...base,
    syncState,
  });
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

function toCodexSandboxParam(
  raw: unknown
): Record<string, unknown> | string | null {
  if (!raw) return null;
  if (typeof raw === "string") {
    const mode = normalizeSandboxModeValue(raw);
    if (mode === "workspace-write") {
      return {
        type: "workspaceWrite",
        networkAccess: true,
        writableRoots: [],
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      };
    }
    if (mode) return mode;
    return null;
  }
  if (typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;
  const mode = normalizeSandboxModeValue(obj.mode ?? obj.type);
  if (mode === "danger-full-access") return "danger-full-access";
  if (mode === "read-only") return "read-only";
  if (mode === "workspace-write") {
    const writableRoots = Array.isArray(obj.writableRoots)
      ? obj.writableRoots.map((entry) => String(entry)).filter((entry) => entry.trim().length > 0)
      : [];
    return {
      type: "workspaceWrite",
      // Keep workspace-write online regardless of stale persisted flags.
      networkAccess: true,
      writableRoots,
      excludeTmpdirEnvVar: Boolean(obj.excludeTmpdirEnvVar ?? false),
      excludeSlashTmp: Boolean(obj.excludeSlashTmp ?? false),
    };
  }
  return null;
}

function injectWorkspaceRoots(
  sandbox: Record<string, unknown>,
  cwd: string
): Record<string, unknown> {
  const mode = normalizeSandboxModeValue(sandbox.mode ?? sandbox.type);
  if (mode !== "workspace-write") return sandbox;
  const roots = Array.isArray(sandbox.writableRoots) ? sandbox.writableRoots : [];
  if (roots.length > 0) return sandbox;
  return { ...sandbox, writableRoots: [cwd] };
}

function normalizeSandboxModeValue(raw: unknown): "read-only" | "workspace-write" | "danger-full-access" | null {
  const normalized = normalizeNonEmptyString(raw);
  if (!normalized) return null;
  const compact = normalized.trim().toLowerCase().replace(/[\s_-]/g, "");
  if (compact === "readonly") return "read-only";
  if (compact === "workspacewrite") return "workspace-write";
  if (compact === "dangerfullaccess") return "danger-full-access";
  return null;
}

const AGENTS_CONTEXT_MARKER = "[LABOS_AGENTS_CONTEXT]";
const PROJECT_CONTEXT_MARKER = "[LABOS_PROJECT_CONTEXT]";
const MAX_SNIPPET_CHARS = 2_200;
const HISTORY_FALLBACK_MARKER = "[LABOS_SESSION_HISTORY_FALLBACK]";
const MAX_HISTORY_FALLBACK_CHARS = 9_000;
const MAX_CONTEXT_DEVELOPER_INSTRUCTIONS_CHARS = 16_000;

type TurnInputWithProjectContext = {
  input: UserInput[];
  developerInstructions: string | null;
};

async function buildTurnInputWithProjectContext(
  repository: CodexRepository,
  projectId: string | null,
  input: UserInput[]
): Promise<TurnInputWithProjectContext> {
  const clonedInput = input.map((part) => ({ ...part }));
  if (!projectId || !input.length) return { input: clonedInput, developerInstructions: null };

  const promptText = input
    .map((part) => (part.type === "text" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();

  if (!promptText) return { input: clonedInput, developerInstructions: null };

  const hasAgentsMarker = promptText.includes(AGENTS_CONTEXT_MARKER);
  const hasProjectMarker = promptText.includes(PROJECT_CONTEXT_MARKER);

  let stream;
  if (!hasProjectMarker) {
    const stateDir = resolveRepositoryStateDirectory(repository);
    try {
      stream = await buildProjectFileContextStream(repository.dbPool(), projectId, promptText, {
        getOpenAIApiKey: async () => (stateDir ? await loadOpenAIApiKeyFromStateDir(stateDir) : undefined),
        fileLimit: 40,
        snippetLimit: 6,
      });
    } catch {
      stream = { files: [], snippets: [] };
    }
  } else {
    stream = { files: [], snippets: [] };
  }

  const agentsContent = hasAgentsMarker ? "" : await readAgentsBootstrapFile(repository, projectId);
  const snippets = stream.snippets.length > 0
    ? [...stream.snippets]
      .sort((a, b) => b.score - a.score)
      .map((snippet, index) => {
        const content = snippet.content.replace(/\s+/g, " ").trim().slice(0, MAX_SNIPPET_CHARS);
        return `(${index + 1}) ${snippet.path}#${snippet.chunkIndex}\n${content}`;
      })
    : [];

  const fileCatalogEntries = stream.files
    .filter((f) => f.indexStatus === "indexed" && f.indexSummary)
    .map((f) => `- ${f.path}: ${f.indexSummary}`)
    .slice(0, 20);

  console.log(`[context] project=${projectId} files=${stream.files.length} snippets=${stream.snippets.length} catalogEntries=${fileCatalogEntries.length}`);

  if (!agentsContent && snippets.length === 0 && fileCatalogEntries.length === 0) {
    console.log(`[context] project=${projectId} no context injected (agents=${!!agentsContent} snippets=${snippets.length} catalog=${fileCatalogEntries.length})`);
    return { input: clonedInput, developerInstructions: null };
  }

  const contextParts: string[] = [];
  if (agentsContent) {
    contextParts.push(`${AGENTS_CONTEXT_MARKER}
Use this AGENTS.md context as authoritative project behavior guidance:
${agentsContent}`);
  }
  if (snippets.length > 0 || fileCatalogEntries.length > 0) {
    const parts: string[] = [];
    if (fileCatalogEntries.length > 0) {
      parts.push(`Uploaded project files:\n${fileCatalogEntries.join("\n")}`);
    }
    if (snippets.length > 0) {
      parts.push(`Relevant indexed snippets:\n${snippets.join("\n\n")}`);
    }
    contextParts.push(`${PROJECT_CONTEXT_MARKER}\n${parts.join("\n\n")}`);
  }
  const contextBlock = contextParts.join("\n\n").trim();
  console.log(`[context] project=${projectId} injecting ${contextBlock.length} chars of developer_instructions`);
  return {
    input: clonedInput,
    developerInstructions: contextBlock || null,
  };
}

async function readAgentsBootstrapFile(repository: CodexRepository, projectId: string): Promise<string> {
  const stateDir = resolveRepositoryStateDirectory(repository);
  if (!stateDir) return "";
  const agentsPath = path.join(stateDir, "projects", projectId, "bootstrap", "AGENTS.md");
  try {
    const content = await readFile(agentsPath, "utf8");
    return String(content ?? "").trim();
  } catch {
    return "";
  }
}

function resolveRepositoryStateDirectory(repository: CodexRepository): string | null {
  const maybe = repository as unknown as { stateDirectory?: () => string };
  if (typeof maybe.stateDirectory !== "function") return null;
  const value = maybe.stateDirectory();
  return typeof value === "string" && value.trim() ? value : null;
}

function injectHistoryFallbackContext(input: UserInput[], turns: Turn[]): string | null {
  if (!input.length || turns.length === 0) return null;

  const promptText = input
    .map((part) => (part.type === "text" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();
  if (promptText.includes(HISTORY_FALLBACK_MARKER)) return null;

  const transcript = buildHistoryFallbackTranscript(turns);
  if (!transcript) return null;

  return `${HISTORY_FALLBACK_MARKER}
Remote thread history hydration failed. Use this conversation transcript context:
${transcript}`.trim();
}

function buildHistoryFallbackTranscript(turns: Turn[]): string {
  const lines: string[] = [];
  for (const turn of turns) {
    for (const item of turn.items) {
      if (item.type === "userMessage") {
        const userItem = item as Extract<ThreadItem, { type: "userMessage" }>;
        const input = Array.isArray(userItem.content) ? userItem.content : [];
        const text = input
          .map((part: UserInput) => {
            if (part.type === "text") return part.text;
            if (part.type === "image") return `[image:${part.url}]`;
            if (part.type === "localImage") return `[localImage:${part.path}]`;
            if (part.type === "skill") return `[skill:${part.name}]`;
            if (part.type === "mention") return `[mention:${part.name}]`;
            return "";
          })
          .filter(Boolean)
          .join("\n")
          .trim();
        if (text) {
          lines.push(`User: ${text}`);
        }
        continue;
      }
      if (item.type === "agentMessage") {
        const text = String(item.text ?? "").trim();
        if (text) {
          lines.push(`Assistant: ${text}`);
        }
      }
    }
  }

  if (lines.length === 0) return "";
  const joined = lines.join("\n");
  if (joined.length <= MAX_HISTORY_FALLBACK_CHARS) return joined;
  return joined.slice(joined.length - MAX_HISTORY_FALLBACK_CHARS);
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

export async function handleTurnSteer(
  ctx: TurnHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  const threadId = normalizeNonEmptyString(params.threadId);
  const turnId = normalizeNonEmptyString(params.turnId);
  const text = normalizeNonEmptyString(params.text);
  const rawInput = params.input;
  if (!threadId || !turnId || (!text && rawInput == null)) {
    throw new Error("Missing threadId, turnId, or steer input");
  }

  const threadRecord = await ctx.repository.getThreadRecord(threadId);
  if (!threadRecord) {
    throw new Error("Thread not found");
  }

  const input: UserInput[] = rawInput != null
    ? await normalizeUserInputList(ctx.repository, threadRecord.projectId, threadId, rawInput)
    : [
        {
          type: "text",
          text: text ?? "",
          text_elements: [] as Record<string, unknown>[],
        },
      ];

  const hasMeaningfulInput = input.some((part) => {
    if (part.type === "text") {
      return String(part.text ?? "").trim().length > 0;
    }
    return true;
  });
  if (!hasMeaningfulInput) {
    throw new Error("Missing steer input");
  }

  const engine = await ctx.engines.getEngine(threadRecord.engine);
  if (!engine.steerTurn) {
    throw new Error(`Engine ${threadRecord.engine} does not support turn/steer`);
  }
  return await engine.steerTurn({
    threadId,
    turnId,
    input,
  });
}

async function normalizeUserInputList(
  repository: CodexRepository,
  projectId: string | null,
  threadId: string,
  raw: unknown
): Promise<UserInput[]> {
  if (!Array.isArray(raw)) {
    return [
      {
        type: "text",
        text: "",
        text_elements: [],
      },
    ];
  }

  const normalized = (
    await Promise.all(
      raw.map((entry) => normalizeUserInput(repository, projectId, threadId, entry))
    )
  ).filter((entry): entry is UserInput => entry != null);

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

async function normalizeUserInput(
  repository: CodexRepository,
  projectId: string | null,
  threadId: string,
  raw: unknown
): Promise<UserInput | null> {
  if (!raw || typeof raw !== "object") return null;
  const entry = raw as Record<string, unknown>;
  const type = normalizeNonEmptyString(entry.type)?.toLowerCase();
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
  if (type === "localimage") {
    return {
      type: "localImage",
      path: String(entry.path ?? ""),
    };
  }
  if (type === "attachment") {
    const name = String(entry.name ?? entry.filename ?? "attachment").trim() || "attachment";
    const mimeType = entry.mimeType == null ? null : String(entry.mimeType);
    const inlineDataBase64 = normalizeNonEmptyString(entry.inlineDataBase64 ?? entry.inline_data_base64) ?? "";
    if (!inlineDataBase64) return null;

    let data: Buffer;
    try {
      data = Buffer.from(inlineDataBase64, "base64");
    } catch {
      return null;
    }
    if (!data.length) return null;

    const ext = path.extname(name).toLowerCase().replace(/^\./, "");
    const isImage =
      (mimeType ?? "").toLowerCase().startsWith("image/")
      || ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"].includes(ext);
    const safeName = sanitizeStagedFileName(name);
    const stagedPath = await stageCodexInputAttachment({
      repository,
      projectId,
      threadId,
      fileName: safeName,
      data,
    });

    if (isImage) {
      return {
        type: "localImage",
        path: stagedPath,
      };
    }

    return {
      type: "mention",
      name: safeName,
      path: stagedPath,
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

function sanitizeStagedFileName(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "attachment";
  const base = trimmed.replace(/[\\/]/g, "_");
  return base.length > 180 ? base.slice(base.length - 180) : base;
}

async function stageCodexInputAttachment(args: {
  repository: CodexRepository;
  projectId: string | null;
  threadId: string;
  fileName: string;
  data: Buffer;
}): Promise<string> {
  const stateDir = args.repository.stateDirectory();
  const projectId = normalizeNonEmptyString(args.projectId) ?? null;
  const baseDir = projectId
    ? path.join(stateDir, "projects", projectId, "cache", "codex-inputs", args.threadId)
    : path.join(stateDir, "codex", "inputs", args.threadId);
  await mkdir(baseDir, { recursive: true });
  const finalName = `${uuidv4()}-${args.fileName}`;
  const destination = path.join(baseDir, finalName);
  await writeFile(destination, args.data);
  return destination;
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

async function normalizeThreadCwdForProject(
  repository: CodexRepository,
  projectId: string | null,
  cwd: string
): Promise<string> {
  if (!projectId) return cwd;
  const projectWorkspace = await resolveProjectWorkspacePath(repository, projectId);
  const normalizedCwd = normalizeNonEmptyString(cwd);
  if (!normalizedCwd) return projectWorkspace;

  const projectRelative = extractProjectRelativeCwd(normalizedCwd, projectId);
  if (projectRelative != null) {
    return projectRelative ? path.join(projectWorkspace, projectRelative) : projectWorkspace;
  }

  if (path.isAbsolute(normalizedCwd)) {
    return projectWorkspace;
  }

  const candidate = path.resolve(projectWorkspace, normalizedCwd);
  if (!candidate.startsWith(projectWorkspace + path.sep) && candidate !== projectWorkspace) {
    return projectWorkspace;
  }
  return candidate;
}

function extractProjectRelativeCwd(rawCwd: string, projectId: string): string | null {
  const segments = rawCwd
    .replaceAll("\\", "/")
    .split("/")
    .map((segment) => segment.trim())
    .filter(Boolean);
  for (let index = 0; index < segments.length - 1; index += 1) {
    if (segments[index] !== "projects") continue;
    if (segments[index + 1] !== projectId) continue;
    return segments.slice(index + 2).join("/");
  }
  return null;
}

async function resolveProjectWorkspacePath(repository: CodexRepository, projectId: string): Promise<string> {
  const workspaceRoot = await resolveWorkspaceRoot(repository);
  if (!workspaceRoot) {
    throw new Error("CAPABILITY_MISSING: node workspaceRoot is unavailable");
  }
  return path.join(workspaceRoot, "projects", projectId);
}

async function resolveWorkspaceRoot(repository: CodexRepository): Promise<string | null> {
  const envRoot = normalizeNonEmptyString(process.env.LABOS_HPC_WORKSPACE_ROOT);
  if (envRoot) return envRoot;

  let rows: any[] = [];
  try {
    rows = await repository.query<any>(
      `SELECT permissions
       FROM nodes
       ORDER BY last_seen_at DESC, created_at DESC
       LIMIT 20`
    );
  } catch {
    return null;
  }

  for (const row of rows) {
    const parsed = parseJsonObject(row?.permissions);
    const workspaceRoot = normalizeNonEmptyString(parsed?.workspaceRoot);
    if (workspaceRoot) return workspaceRoot;
  }

  return null;
}

function parseJsonObject(raw: unknown): Record<string, unknown> | null {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) return raw as Record<string, unknown>;
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

function withUpdatedThreadStatusCwd(
  rawStatusJson: string | null | undefined,
  cwd: string,
  settings: {
    modelProvider: string;
    model: string | null;
    approvalPolicy: string;
    sandbox: Record<string, unknown>;
    reasoningEffort: string | null;
  }
): string {
  const base = parseJsonObject(rawStatusJson) ?? {
    modelProvider: settings.modelProvider,
    model: settings.model,
    approvalPolicy: settings.approvalPolicy,
    sandbox: settings.sandbox,
    reasoningEffort: settings.reasoningEffort,
  };
  return JSON.stringify({
    ...base,
    cwd,
  });
}

function normalizePlanMode(raw: unknown): boolean {
  if (typeof raw === "boolean") return raw;
  if (typeof raw === "string") {
    const normalized = raw.trim().toLowerCase();
    if (normalized === "true" || normalized === "1" || normalized === "yes" || normalized === "on") return true;
    if (normalized === "false" || normalized === "0" || normalized === "no" || normalized === "off") return false;
  }
  return false;
}

function buildCollaborationMode(
  planMode: boolean,
  model: string | null,
  contextDeveloperInstructions?: string | null
): {
  mode: "plan" | "default";
  settings: {
    model: string;
    reasoning_effort: string | null;
    developer_instructions: string | null;
  };
} | null {
  const normalizedModel = normalizeNonEmptyString(model);
  if (!normalizedModel) return null;
  const instructionsParts = [
    planMode ? PLAN_MODE_DEVELOPER_INSTRUCTIONS : null,
    normalizeNonEmptyString(contextDeveloperInstructions),
  ].filter((part): part is string => Boolean(part && part.trim()));
  const developerInstructions = instructionsParts.join("\n\n").trim();
  const clippedDeveloperInstructions = developerInstructions
    ? developerInstructions.slice(0, MAX_CONTEXT_DEVELOPER_INSTRUCTIONS_CHARS)
    : null;
  return {
    mode: planMode ? "plan" : "default",
    settings: {
      model: normalizedModel,
      reasoning_effort: null,
      developer_instructions: clippedDeveloperInstructions,
    },
  };
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
    const userItem = item as Extract<ThreadItem, { type: "userMessage" }>;
    const content: Array<Record<string, unknown>> = [];
    const inputParts = Array.isArray(userItem.content) ? userItem.content : [];
    for (const part of inputParts) {
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
