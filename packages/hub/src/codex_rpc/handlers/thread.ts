import process from "node:process";
import path from "node:path";
import { v4 as uuidv4 } from "uuid";

import { loadOrCreateHubConfig, resolveConfiguredWorkspaceRoot } from "../../config.js";
import { assertExplicitModelSupportedByCodexAppServer, resolveHubProvider } from "../../model.js";
import { normalizeWorkspacePath } from "../../workspace_paths.js";
import { normalizeEngineName, type CodexEngineRegistry } from "../engine_registry.js";
import type { CodexRepository } from "../repository.js";
import { nowUnixSeconds, previewFromText, type Thread, type ThreadItem, type Turn } from "../types.js";

type ThreadHandlerContext = {
  repository: CodexRepository;
  engines: CodexEngineRegistry;
};

type StoredThreadSettings = {
  modelProvider: string;
  model: string | null;
  cwd: string;
  approvalPolicy: string;
  sandbox: Record<string, unknown>;
  reasoningEffort: string | null;
};

export async function handleThreadStart(
  ctx: ThreadHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  const provider = resolveHubProvider(null);

  const sessionId = normalizeNonEmptyString(params.sessionId);
  const explicitProjectId = normalizeNonEmptyString(params.projectId);

  let sessionRecord: any | null = null;
  if (sessionId) {
    const rows = await ctx.repository.query<any>(
      `SELECT id, project_id, backend_engine, codex_model_provider, codex_model, codex_approval_policy, codex_sandbox_json
       FROM sessions
       WHERE id=$1
       LIMIT 1`,
      [sessionId]
    );
    sessionRecord = rows[0] ?? null;
    if (!sessionRecord) {
      throw new Error("Session not found");
    }
  }

  const projectId = sessionRecord?.project_id ? String(sessionRecord.project_id) : explicitProjectId ?? null;

  const engineName =
    normalizeEngineName(params.engine) ?? normalizeEngineName(sessionRecord?.backend_engine) ?? ctx.engines.defaultEngineName();
  const resolvedProjectWorkspace = await resolveProjectWorkspacePath(ctx.repository, projectId);
  const cwd = normalizeNonEmptyString(params.cwd) ?? resolvedProjectWorkspace ?? process.cwd();
  const modelProvider =
    normalizeNonEmptyString(params.modelProvider) ?? normalizeNonEmptyString(sessionRecord?.codex_model_provider) ?? provider.provider;
  const explicitModel = normalizeNonEmptyString(params.model);
  if (explicitModel) {
    await assertExplicitModelSupportedByCodexAppServer({
      model: explicitModel,
      engines: ctx.engines,
    });
  }
  const model = explicitModel ?? normalizeNonEmptyString(sessionRecord?.codex_model) ?? provider.defaultModelId ?? null;
  const approvalPolicy =
    normalizeApprovalPolicy(params.approvalPolicy) ||
    normalizeApprovalPolicy(sessionRecord?.codex_approval_policy) ||
    normalizeApprovalPolicy(null);
  const sandbox =
    normalizeSandboxPolicy(params.sandbox) ??
    normalizeSandboxPolicy(parseJsonObject(sessionRecord?.codex_sandbox_json));

  const settings: StoredThreadSettings = {
    modelProvider,
    model,
    cwd,
    approvalPolicy,
    sandbox,
    reasoningEffort: null,
  };

  if (engineName === "codex-app-server") {
    const engine = await ctx.engines.getEngine(engineName);
    if (engine.threadStart) {
      const engineParams = stripEngineOverride(params);
      // thread/start only accepts a plain string sandbox mode enum
      // ("read-only" | "workspace-write" | "danger-full-access").
      // The full SandboxPolicy object (with networkAccess, writableRoots, etc.)
      // is passed via sandboxPolicy in turn/start instead.
      const sandboxMode = toCodexSandboxModeFromPolicy(sandbox);
      if (sandboxMode) {
        engineParams.sandbox = sandboxMode;
      }
      const proxied = await engine.threadStart(engineParams);
      const threadRaw = (proxied.thread ?? null) as Record<string, unknown> | null;
      if (threadRaw && typeof threadRaw.id === "string") {
        const preview = normalizeNonEmptyString(threadRaw.preview) ?? "";
        await ctx.repository.createThread({
          id: threadRaw.id,
          projectId,
          cwd: normalizeNonEmptyString(threadRaw.cwd) ?? cwd,
          modelProvider: normalizeNonEmptyString(threadRaw.modelProvider) ?? modelProvider,
          modelId: model,
          preview,
          statusJson: JSON.stringify(settings),
          engine: engineName,
          createdAt: Number(threadRaw.createdAt ?? nowUnixSeconds()),
        });
        if (sessionId) {
          await ctx.repository.assignThreadToSession({ threadId: threadRaw.id, sessionId });
          await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
            threadRaw.id,
            new Date().toISOString(),
            sessionId,
          ]);
        }
      }
      return proxied;
    }
  }

  const threadId = `thr_${uuidv4()}`;
  const createdAt = nowUnixSeconds();
  await ctx.repository.createThread({
    id: threadId,
    projectId,
    cwd,
    modelProvider,
    modelId: model,
    preview: "",
    statusJson: JSON.stringify(settings),
    engine: engineName,
    createdAt,
  });
  if (sessionId) {
    await ctx.repository.assignThreadToSession({ threadId, sessionId });
    await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
      threadId,
      new Date().toISOString(),
      sessionId,
    ]);
  }

  const thread: Thread = {
    id: threadId,
    preview: "",
    modelProvider,
    createdAt,
    updatedAt: createdAt,
    path: null,
    cwd,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  return {
    thread,
    model,
    modelProvider,
    cwd,
    approvalPolicy,
    sandbox,
    reasoningEffort: null,
  };
}

export async function handleThreadResume(
  ctx: ThreadHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
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

  const existing = await ctx.repository.getThreadRecord(threadId);
  const storedEngine = existing?.engine ?? null;

  if (storedEngine === "codex-app-server") {
    const engine = await ctx.engines.getEngine(storedEngine);
    if (engine.threadResume) {
      const proxied = await engine.threadResume(params);
      await maybePersistThreadFromResponse(ctx.repository, proxied, storedEngine);
      return proxied;
    }
  }

  const thread = await ctx.repository.readThread(threadId, true);
  if (!thread) {
    throw new Error("Thread not found");
  }

  const settings = parseThreadSettings(existing?.statusJson, thread);
  return {
    thread,
    model: settings.model,
    modelProvider: settings.modelProvider,
    cwd: settings.cwd,
    approvalPolicy: settings.approvalPolicy,
    sandbox: settings.sandbox,
    reasoningEffort: settings.reasoningEffort,
  };
}

export async function handleThreadRead(
  ctx: ThreadHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
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

  const existing = await ctx.repository.getThreadRecord(threadId);
  if (existing?.engine === "codex-app-server") {
    const engine = await ctx.engines.getEngine(existing.engine);
    if (engine.threadRead) {
      const proxied = await engine.threadRead({
        ...stripEngineOverride(params),
        threadId,
      });
      await maybePersistThreadFromResponse(ctx.repository, proxied, existing.engine);
      return proxied;
    }
  }

  const includeTurns = Boolean(params.includeTurns);
  const thread = await ctx.repository.readThread(threadId, includeTurns);
  if (!thread) {
    throw new Error("Thread not found");
  }

  return { thread };
}

export async function handleThreadRollback(
  ctx: ThreadHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
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

  const numTurns = normalizeNonNegativeInteger(params.numTurns);
  if (numTurns == null) {
    throw new Error("Missing or invalid numTurns");
  }

  const existing = await ctx.repository.getThreadRecord(threadId);
  if (!existing) {
    throw new Error("Thread not found");
  }

  if (existing.engine === "codex-app-server") {
    const engine = await ctx.engines.getEngine(existing.engine);
    if (engine.threadRollback) {
      try {
        const proxied = await engine.threadRollback({
          threadId,
          numTurns,
        });
        await maybePersistThreadFromResponse(ctx.repository, proxied, existing.engine);
        return proxied;
      } catch {
        // Fall back to local rollback when the child thread cannot be found
        // or the engine does not currently support rollback in this process.
      }
    }
  }

  const current = await ctx.repository.readThread(threadId, true);
  if (!current) {
    throw new Error("Thread not found");
  }
  if (numTurns <= 0 || current.turns.length === 0) {
    return { thread: current };
  }

  const removeCount = Math.min(numTurns, current.turns.length);
  const removedTurnIds = current.turns.slice(current.turns.length - removeCount).map((turn) => turn.id);
  await ctx.repository.removeTurns(threadId, removedTurnIds);

  const updated = await ctx.repository.readThread(threadId, true);
  if (!updated) {
    throw new Error("Thread not found");
  }

  await ctx.repository.updateThread({
    id: threadId,
    preview: updateThreadPreviewFromItems(updated.turns),
    updatedAt: nowUnixSeconds(),
  });

  const reloaded = await ctx.repository.readThread(threadId, true);
  return { thread: reloaded ?? updated };
}

export async function handleThreadList(
  ctx: ThreadHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = (rawParams ?? {}) as Record<string, unknown>;
  const cwd = normalizeNonEmptyString(params.cwd);
  const archived = typeof params.archived === "boolean" ? params.archived : null;
  const modelProviders = Array.isArray(params.modelProviders)
    ? params.modelProviders.map((entry) => String(entry)).filter(Boolean)
    : null;
  const limit = typeof params.limit === "number" ? params.limit : null;

  const records = await ctx.repository.listThreadRecords({
    cwd,
    archived,
    modelProviders,
    limit,
  });

  const data: Thread[] = records.map((record) => ({
    id: record.id,
    preview: record.preview,
    modelProvider: record.modelProvider,
    createdAt: record.createdAt,
    updatedAt: record.updatedAt,
    path: null,
    cwd: record.cwd,
    cliVersion: "epoch/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  }));

  return {
    data,
    nextCursor: null,
  };
}

export function parseThreadSettings(raw: string | null | undefined, thread: Thread): StoredThreadSettings {
  if (raw) {
    try {
      const parsed = JSON.parse(raw) as Partial<StoredThreadSettings>;
      return {
        modelProvider: normalizeNonEmptyString(parsed.modelProvider) ?? thread.modelProvider,
        model: normalizeNonEmptyString(parsed.model) ?? null,
        cwd: normalizeNonEmptyString(parsed.cwd) ?? thread.cwd,
        approvalPolicy: normalizeApprovalPolicy(parsed.approvalPolicy),
        sandbox: normalizeSandboxPolicy(parsed.sandbox),
        reasoningEffort: normalizeNonEmptyString(parsed.reasoningEffort) ?? null,
      };
    } catch {
      // fall through
    }
  }
  return {
    modelProvider: thread.modelProvider,
    model: null,
    cwd: thread.cwd,
    approvalPolicy: "on-request",
    sandbox: normalizeSandboxPolicy(null),
    reasoningEffort: null,
  };
}

export function updateThreadPreviewFromItems(turns: Turn[]): string {
  for (let i = turns.length - 1; i >= 0; i -= 1) {
    const turn = turns[i];
    for (let j = turn.items.length - 1; j >= 0; j -= 1) {
      const item = turn.items[j];
      if (item.type === "userMessage") {
        const content = Array.isArray((item as any).content) ? ((item as any).content as Array<Record<string, unknown>>) : [];
        const text = content
          .map((part: Record<string, unknown>) => {
            if (part.type === "text" && typeof part.text === "string") return part.text;
            return "";
          })
          .filter(Boolean)
          .join("\n")
          .trim();
        if (text) return previewFromText(text);
      }
      if (item.type === "agentMessage") {
        const text = String(item.text ?? "").trim();
        if (text) return previewFromText(text);
      }
    }
  }
  return "";
}

function toCodexSandboxModeFromPolicy(policy: Record<string, unknown>): string | null {
  const type = normalizeNonEmptyString(policy.type) ?? normalizeNonEmptyString(policy.mode);
  if (type === "workspaceWrite" || type === "workspace-write" || type === "workspace_write") return "workspace-write";
  if (type === "readOnly" || type === "read-only" || type === "read_only") return "read-only";
  if (type === "dangerFullAccess" || type === "danger-full-access" || type === "danger_full_access") return "danger-full-access";
  return null;
}

function normalizeApprovalPolicy(raw: unknown): string {
  const value = normalizeNonEmptyString(raw)?.toLowerCase();
  switch (value) {
    case "untrusted":
    case "on-failure":
    case "on-request":
    case "never":
      return value;
    default:
      return "on-request";
  }
}

async function resolveProjectWorkspacePath(repository: CodexRepository, projectId: string | null): Promise<string | null> {
  if (!projectId) return null;

  try {
    const rows = await repository.query<{ hpc_workspace_path: string | null }>(
      `SELECT hpc_workspace_path
       FROM projects
       WHERE id=$1
       LIMIT 1`,
      [projectId]
    );
    const persisted = normalizeWorkspacePath(rows[0]?.hpc_workspace_path);
    if (persisted) {
      return persisted;
    }
  } catch {
    // ignore lookup failures and fall back to the configured default root
  }

  const workspaceRoot = await resolveWorkspaceRoot(repository);
  return path.join(workspaceRoot, "projects", projectId);
}

async function resolveWorkspaceRoot(repository: CodexRepository): Promise<string> {
  const stateDir = repository.stateDirectory();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false }).catch(() => null);
  return resolveConfiguredWorkspaceRoot({
    stateDir,
    config,
    env: process.env,
  });
}

function parseJsonObject(raw: unknown): Record<string, unknown> | null {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

function normalizeSandboxPolicy(raw: unknown): Record<string, unknown> {
  if (raw && typeof raw === "object" && !Array.isArray(raw)) {
    const obj = raw as Record<string, unknown>;
    const mode = normalizeNonEmptyString(obj.mode) ?? normalizeNonEmptyString(obj.type);
    if (mode === "danger-full-access" || mode === "dangerfullaccess" || mode === "danger_full_access" || mode === "dangerFullAccess") {
      return { type: "dangerFullAccess" };
    }
    if (mode === "read-only" || mode === "readonly" || mode === "read_only" || mode === "readOnly") {
      return { type: "readOnly" };
    }
    return {
      type: "workspaceWrite",
      networkAccess: Boolean(obj.networkAccess ?? true),
      writableRoots: Array.isArray(obj.writableRoots) ? obj.writableRoots : [],
      excludeTmpdirEnvVar: Boolean(obj.excludeTmpdirEnvVar ?? false),
      excludeSlashTmp: Boolean(obj.excludeSlashTmp ?? false),
    };
  }
  const mode = normalizeNonEmptyString(raw)?.toLowerCase();
  switch (mode) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return { type: "readOnly" };
    default:
      return {
        type: "workspaceWrite",
        writableRoots: [process.cwd()],
        networkAccess: true,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      };
  }
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeNullableString(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeNonNegativeInteger(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    const next = Math.floor(raw);
    return next >= 0 ? next : null;
  }
  if (typeof raw === "string" && raw.trim()) {
    const parsed = Number(raw);
    if (Number.isFinite(parsed)) {
      const next = Math.floor(parsed);
      return next >= 0 ? next : null;
    }
  }
  return null;
}

function stripEngineOverride(params: Record<string, unknown>): Record<string, unknown> {
  const clone: Record<string, unknown> = { ...params };
  delete clone.engine;
  return clone;
}

export async function maybePersistThreadFromResponse(repository: CodexRepository, response: Record<string, unknown>, engine: string) {
  const threadRaw = (response.thread ?? null) as Record<string, unknown> | null;
  if (!threadRaw || typeof threadRaw.id !== "string") return;
  const threadId = String(threadRaw.id);
  const scopedIds = engine === "codex-app-server";

  const existing = await repository.getThreadRecord(threadId);
  const createdAt = Number(threadRaw.createdAt ?? nowUnixSeconds());
  const updatedAt = Number(threadRaw.updatedAt ?? createdAt);

  if (!existing) {
    await repository.createThread({
      id: threadId,
      projectId: null,
      cwd: normalizeNonEmptyString(threadRaw.cwd) ?? process.cwd(),
      modelProvider: normalizeNonEmptyString(threadRaw.modelProvider) ?? "unknown",
      modelId: null,
      preview: normalizeNonEmptyString(threadRaw.preview) ?? "",
      statusJson: null,
      engine,
      createdAt,
    });
    if (updatedAt !== createdAt) {
      await repository.updateThread({ id: threadId, updatedAt });
    }
    return;
  }

  await repository.updateThread({
    id: existing.id,
    cwd: normalizeNonEmptyString(threadRaw.cwd) ?? existing.cwd,
    modelProvider: normalizeNonEmptyString(threadRaw.modelProvider) ?? existing.modelProvider,
    preview: normalizeNonEmptyString(threadRaw.preview) ?? existing.preview,
    engine,
    updatedAt,
  });

  const turnsRaw = Array.isArray(threadRaw.turns) ? threadRaw.turns : null;
  if (!turnsRaw) return;

  const normalizedTurns = turnsRaw
    .map((turn) => normalizeTurnSnapshot(turn))
    .filter((turn): turn is { id: string; status: Turn["status"]; error: Turn["error"]; items: ThreadItem[] } => turn != null);

  // Some app-server variants reuse simple turn/item IDs (e.g. "1", "2")
  // across different threads. Scope persisted IDs by thread to avoid global
  // PK collisions in Epoch storage while keeping wire payloads unchanged.
  const scopedTurns = normalizedTurns.map((turn) => ({
    ...turn,
    id: scopedTurnId(threadId, turn.id, scopedIds),
  }));

  const existingTurns = await repository.listTurnRecords(threadId);
  const existingTurnIds = new Set(existingTurns.map((turn) => turn.id));
  const desiredTurnIds = new Set(scopedTurns.map((turn) => turn.id));
  const staleTurnIds = existingTurns.map((turn) => turn.id).filter((id) => !desiredTurnIds.has(id));
  if (staleTurnIds.length > 0) {
    await repository.removeTurns(threadId, staleTurnIds);
  }

  const createdAtBase = nowUnixSeconds();
  for (const [index, turn] of scopedTurns.entries()) {
    const turnCreatedAt = createdAtBase + index;
    if (!existingTurnIds.has(turn.id)) {
      await repository.createTurn({
        id: turn.id,
        threadId,
        status: turn.status,
        error: turn.error,
        createdAt: turnCreatedAt,
      });
      existingTurnIds.add(turn.id);
    } else {
      await repository.updateTurn({
        id: turn.id,
        status: turn.status,
        error: turn.error,
        completedAt: turn.status === "inProgress" ? null : nowUnixSeconds(),
        touchThreadId: threadId,
      });
    }

    for (const item of turn.items) {
      const rawItemId = String(item.id);
      await repository.upsertItem({
        id: scopedItemId(threadId, rawItemId, scopedIds),
        threadId,
        turnId: turn.id,
        type: String(item.type),
        payload: item,
        updatedAt: nowUnixSeconds(),
      });
    }
  }
}

function scopedTurnId(threadId: string, turnId: string, scoped: boolean): string {
  if (!scoped) return turnId;
  return `${threadId}::turn::${turnId}`;
}

function scopedItemId(threadId: string, itemId: string, scoped: boolean): string {
  if (!scoped) return itemId;
  return `${threadId}::item::${itemId}`;
}

function normalizeTurnSnapshot(
  raw: unknown
): { id: string; status: Turn["status"]; error: Turn["error"]; items: ThreadItem[] } | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const record = raw as Record<string, unknown>;
  const id = normalizeNonEmptyString(record.id);
  if (!id) return null;

  const statusRaw = normalizeNonEmptyString(record.status) ?? "completed";
  const status: Turn["status"] =
    statusRaw === "inProgress" || statusRaw === "completed" || statusRaw === "failed" || statusRaw === "interrupted"
      ? statusRaw
      : "completed";

  let error: Turn["error"] = null;
  if (record.error && typeof record.error === "object" && !Array.isArray(record.error)) {
    const errorRecord = record.error as Record<string, unknown>;
    const message = normalizeNonEmptyString(errorRecord.message) ?? "unknown error";
    error = {
      message,
      codexErrorInfo: errorRecord.codexErrorInfo ?? null,
      additionalDetails: normalizeNullableString(errorRecord.additionalDetails),
    };
  }

  const itemsRaw = Array.isArray(record.items) ? record.items : [];
  const items = itemsRaw
    .map((item) => normalizeThreadItemSnapshot(item))
    .filter((item): item is ThreadItem => item != null);

  return { id, status, error, items };
}

function normalizeThreadItemSnapshot(raw: unknown): ThreadItem | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const item = raw as Record<string, unknown>;
  const id = normalizeNonEmptyString(item.id);
  const type = normalizeNonEmptyString(item.type);
  if (!id || !type) return null;
  return item as ThreadItem;
}
