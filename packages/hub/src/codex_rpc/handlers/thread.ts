import process from "node:process";
import path from "node:path";
import { v4 as uuidv4 } from "uuid";

import { resolveHubProvider } from "../../model.js";
import { normalizeEngineName, type CodexEngineRegistry } from "../engine_registry.js";
import type { CodexRepository } from "../repository.js";
import { nowUnixSeconds, previewFromText, type Thread, type Turn } from "../types.js";

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
  const cwd = normalizeNonEmptyString(params.cwd) ?? resolveProjectWorkspacePath(projectId) ?? process.cwd();
  const modelProvider =
    normalizeNonEmptyString(params.modelProvider) ?? normalizeNonEmptyString(sessionRecord?.codex_model_provider) ?? provider.provider;
  const model = normalizeNonEmptyString(params.model) ?? normalizeNonEmptyString(sessionRecord?.codex_model) ?? provider.defaultModelId ?? null;
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
      const proxied = await engine.threadStart(stripEngineOverride(params));
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
    cliVersion: "@labos/hub/0.1.0",
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

  const includeTurns = Boolean(params.includeTurns);
  const thread = await ctx.repository.readThread(threadId, includeTurns);
  if (!thread) {
    throw new Error("Thread not found");
  }

  return { thread };
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
    cliVersion: "@labos/hub/0.1.0",
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

function resolveProjectWorkspacePath(projectId: string | null): string | null {
  if (!projectId) return null;
  const workspaceRoot = normalizeNonEmptyString(process.env.LABOS_HPC_WORKSPACE_ROOT);
  if (workspaceRoot) {
    return path.join(workspaceRoot, "projects", projectId);
  }
  return path.join("projects", projectId);
}

function parseJsonObject(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "string") return null;
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
    return raw as Record<string, unknown>;
  }
  const mode = normalizeNonEmptyString(raw)?.toLowerCase();
  switch (mode) {
    case "danger-full-access":
      return { type: "dangerFullAccess" };
    case "read-only":
      return { type: "readOnly" };
    case "workspace-write":
      return {
        type: "workspaceWrite",
        writableRoots: [process.cwd()],
        networkAccess: false,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      };
    default:
      return {
        type: "workspaceWrite",
        writableRoots: [process.cwd()],
        networkAccess: false,
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

function stripEngineOverride(params: Record<string, unknown>): Record<string, unknown> {
  const clone: Record<string, unknown> = { ...params };
  delete clone.engine;
  return clone;
}

async function maybePersistThreadFromResponse(repository: CodexRepository, response: Record<string, unknown>, engine: string) {
  const threadRaw = (response.thread ?? null) as Record<string, unknown> | null;
  if (!threadRaw || typeof threadRaw.id !== "string") return;

  const existing = await repository.getThreadRecord(threadRaw.id);
  const createdAt = Number(threadRaw.createdAt ?? nowUnixSeconds());
  const updatedAt = Number(threadRaw.updatedAt ?? createdAt);

  if (!existing) {
    await repository.createThread({
      id: threadRaw.id,
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
      await repository.updateThread({ id: threadRaw.id, updatedAt });
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
}
