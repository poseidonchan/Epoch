import { appendFile, mkdir, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { v4 as uuidv4 } from "uuid";

import type { CodexEngineRegistry } from "../engine_registry.js";
import type { CodexRepository } from "../repository.js";
import { nowUnixSeconds, type Thread, type ThreadItem, type Turn, type UserInput } from "../types.js";
import { handleThreadRollback, maybePersistThreadFromResponse } from "./thread.js";

type LabosHandlerContext = {
  repository: CodexRepository;
  engines: CodexEngineRegistry;
  pendingUserInputSummaryBySession?: Map<string, { count: number; kind: string | null }>;
  runtimeToken?: string;
};

type ThreadSyncState = "ready" | "needsRemoteHydration";

type EnsureMappedThreadResult = {
  thread: Thread;
  syncState: ThreadSyncState;
  rehydratedFromLegacy: boolean;
};

type SessionPatch = {
  title?: string;
  lifecycle?: "active" | "archived";
  backendEngine?: "codex-app-server";
  codexModel?: string | null;
  codexModelProvider?: string | null;
  codexApprovalPolicy?: string | null;
  codexSandbox?: Record<string, unknown> | null;
};

const DEFAULT_MODEL_PROVIDER = "openai";
const DEFAULT_APPROVAL_POLICY = "on-request";
const STALE_IN_PROGRESS_SECONDS = 10 * 60;
const CODEX_APP_SERVER_THREAD_ID_RE = /^(?:urn:uuid:)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

export async function handleLabosProjectList(
  ctx: LabosHandlerContext,
  _rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const rows = await ctx.repository.query<any>(
    `SELECT id, name, created_at, updated_at, backend_engine, codex_model_provider, codex_model_id,
            codex_approval_policy, codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     ORDER BY updated_at DESC, id DESC`
  );

  return {
    projects: rows.map((row) => mapProjectRow(row)),
  };
}

export async function handleLabosProjectCreate(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const name = normalizeNonEmptyString(params.name) ?? "Untitled Project";
  const backendEngine = normalizeBackendEngine(params.backendEngine) ?? "codex-app-server";
  const codexModelProvider = normalizeNonEmptyString(params.codexModelProvider);
  const codexModel = normalizeNonEmptyString(params.codexModel);
  const codexApprovalPolicy = normalizeNonEmptyString(params.codexApprovalPolicy);
  const codexSandbox = normalizeSandboxPolicy(params.codexSandbox);

  const projectId = uuidv4();
  const nowIso = new Date().toISOString();
  const workspacePath = resolveProjectWorkspacePath(projectId);

  await ctx.repository.query(
    `INSERT INTO projects (
       id, name, created_at, updated_at, backend_engine,
       codex_model_provider, codex_model_id, codex_approval_policy,
       codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [
      projectId,
      name,
      nowIso,
      nowIso,
      backendEngine,
      codexModelProvider,
      codexModel,
      codexApprovalPolicy,
      codexSandbox ? JSON.stringify(codexSandbox) : null,
      workspacePath,
      "queued",
    ]
  );

  await ctx.repository.ensureProjectStorage(projectId);
  await ensureBootstrapDefaults(ctx.repository.stateDirectory(), projectId);
  await enqueueWorkspaceProvisioning(ctx.repository, {
    projectId,
    workspacePath,
    requestedBy: "labos/project/create",
  });

  const rows = await ctx.repository.query<any>(
    `SELECT id, name, created_at, updated_at, backend_engine, codex_model_provider, codex_model_id,
            codex_approval_policy, codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     WHERE id=$1`,
    [projectId]
  );
  const project = rows[0] ? mapProjectRow(rows[0]) : null;
  if (!project) {
    throw new Error("Project creation failed");
  }
  return { project };
}

export async function handleLabosProjectRename(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const name = normalizeNonEmptyString(params.name);
  if (!projectId || !name) {
    throw new Error("Missing projectId or name");
  }

  const nowIso = new Date().toISOString();
  await ctx.repository.query(`UPDATE projects SET name=$1, updated_at=$2 WHERE id=$3`, [name, nowIso, projectId]);

  const rows = await ctx.repository.query<any>(
    `SELECT id, name, created_at, updated_at, backend_engine, codex_model_provider, codex_model_id,
            codex_approval_policy, codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     WHERE id=$1`,
    [projectId]
  );
  if (rows.length === 0) {
    throw new Error("Project not found");
  }
  return { project: mapProjectRow(rows[0]) };
}

export async function handleLabosProjectDelete(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  if (!projectId) {
    throw new Error("Missing projectId");
  }

  const existingRows = await ctx.repository.query<any>(
    `SELECT id, name, created_at, updated_at, backend_engine, codex_model_provider, codex_model_id,
            codex_approval_policy, codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     WHERE id=$1`,
    [projectId]
  );
  if (existingRows.length === 0) {
    throw new Error("Project not found");
  }

  const sessionRows = await ctx.repository.query<any>(`SELECT id FROM sessions WHERE project_id=$1`, [projectId]);
  for (const row of sessionRows) {
    const sessionId = String(row.id ?? "");
    if (!sessionId) continue;
    await ctx.repository.removeSessionThreadMappings(sessionId);
  }

  await ctx.repository.query(`DELETE FROM projects WHERE id=$1`, [projectId]);
  await ctx.repository.removeProjectStorage(projectId);

  return {
    ok: true,
    project: mapProjectRow(existingRows[0]),
  };
}

export async function handleLabosSessionList(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  if (!projectId) {
    throw new Error("Missing projectId");
  }
  const includeArchived = Boolean(params.includeArchived);

  const rows = await ctx.repository.query<any>(
    includeArchived
      ? `SELECT *
         FROM sessions
         WHERE project_id=$1
         ORDER BY updated_at DESC, id DESC`
      : `SELECT *
         FROM sessions
         WHERE project_id=$1 AND lifecycle='active'
         ORDER BY updated_at DESC, id DESC`,
    [projectId]
  );

  return {
    sessions: rows.map((row) => mapSessionRow(row, ctx.pendingUserInputSummaryBySession?.get(String(row.id ?? "")))),
  };
}

export async function handleLabosSessionCreate(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  if (!projectId) {
    throw new Error("Missing projectId");
  }

  const projectRows = await ctx.repository.query<any>(
    `SELECT id, backend_engine, codex_model_provider, codex_model_id, codex_approval_policy, codex_sandbox_json, hpc_workspace_state
     FROM projects WHERE id=$1`,
    [projectId]
  );
  const project = projectRows[0];
  if (!project) {
    throw new Error("Project not found");
  }

  const countRows = await ctx.repository.query<any>(
    `SELECT COUNT(1) AS count
     FROM sessions
     WHERE project_id=$1`,
    [projectId]
  );
  const nextIndex = Number(countRows[0]?.count ?? 0) + 1;

  const title = normalizeNonEmptyString(params.title) ?? `Session ${nextIndex}`;
  const backendEngine = normalizeBackendEngine(params.backendEngine) ?? normalizeBackendEngine(project.backend_engine) ?? "codex-app-server";
  const codexModelProvider = normalizeNonEmptyString(params.codexModelProvider) ?? normalizeNonEmptyString(project.codex_model_provider);
  const codexModel = normalizeNonEmptyString(params.codexModel) ?? normalizeNonEmptyString(project.codex_model_id);
  const codexApprovalPolicy =
    normalizeNonEmptyString(params.codexApprovalPolicy) ?? normalizeNonEmptyString(project.codex_approval_policy) ?? DEFAULT_APPROVAL_POLICY;
  const codexSandbox = Object.prototype.hasOwnProperty.call(params, "codexSandbox")
    ? normalizeSandboxPolicy(params.codexSandbox)
    : safeJsonParseObject(project.codex_sandbox_json) ?? normalizeSandboxPolicy(null);
  const hpcWorkspaceState = normalizeNonEmptyString(project.hpc_workspace_state) ?? "queued";

  const sessionId = uuidv4();
  const nowIso = new Date().toISOString();

  await ctx.repository.query(
    `INSERT INTO sessions (
       id, project_id, title, lifecycle, created_at, updated_at,
       backend_engine, codex_thread_id, codex_model, codex_model_provider,
       codex_approval_policy, codex_sandbox_json, hpc_workspace_state
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,NULL,$8,$9,$10,$11,$12)`,
    [
      sessionId,
      projectId,
      title,
      "active",
      nowIso,
      nowIso,
      backendEngine,
      codexModel,
      codexModelProvider,
      codexApprovalPolicy,
      codexSandbox ? JSON.stringify(codexSandbox) : null,
      hpcWorkspaceState,
    ]
  );

  await ctx.repository.ensureProjectStorage(projectId);
  await ensureSessionTranscript(ctx.repository.stateDirectory(), projectId, sessionId);

  const thread = await createMappedThreadForSession(ctx.repository, ctx.engines, {
    sessionId,
    projectId,
    backendEngine,
    modelProvider: codexModelProvider ?? DEFAULT_MODEL_PROVIDER,
    modelId: codexModel,
    approvalPolicy: codexApprovalPolicy,
    sandbox: codexSandbox ?? normalizeSandboxPolicy(null) ?? {},
  });

  await ctx.repository.query(
    `UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`,
    [thread.id, nowIso, sessionId]
  );

  const sessionRows = await ctx.repository.query<any>(`SELECT * FROM sessions WHERE id=$1`, [sessionId]);
  const session = sessionRows[0]
    ? mapSessionRow(sessionRows[0], ctx.pendingUserInputSummaryBySession?.get(String(sessionRows[0]?.id ?? "")))
    : null;
  if (!session) {
    throw new Error("Session creation failed");
  }

  return {
    session,
    thread,
  };
}

export async function handleLabosSessionUpdate(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  if (!projectId || !sessionId) {
    throw new Error("Missing projectId or sessionId");
  }

  const patch: SessionPatch = {};
  const title = normalizeNonEmptyString(params.title);
  if (title) patch.title = title;
  const lifecycle = normalizeLifecycle(params.lifecycle);
  if (lifecycle) patch.lifecycle = lifecycle;
  const backendEngine = normalizeBackendEngine(params.backendEngine);
  if (backendEngine) patch.backendEngine = backendEngine;
  if (Object.prototype.hasOwnProperty.call(params, "codexModel")) {
    patch.codexModel = normalizeNonEmptyString(params.codexModel);
  }
  if (Object.prototype.hasOwnProperty.call(params, "codexModelProvider")) {
    patch.codexModelProvider = normalizeNonEmptyString(params.codexModelProvider);
  }
  if (Object.prototype.hasOwnProperty.call(params, "codexApprovalPolicy")) {
    patch.codexApprovalPolicy = normalizeNonEmptyString(params.codexApprovalPolicy);
  }
  if (Object.prototype.hasOwnProperty.call(params, "codexSandbox")) {
    patch.codexSandbox = normalizeSandboxPolicy(params.codexSandbox);
  }

  if (Object.keys(patch).length === 0) {
    throw new Error("No updatable fields were provided");
  }

  const updates: string[] = [];
  const values: unknown[] = [];
  if (patch.title) {
    updates.push(`title=$${values.length + 1}`);
    values.push(patch.title);
  }
  if (patch.lifecycle) {
    updates.push(`lifecycle=$${values.length + 1}`);
    values.push(patch.lifecycle);
  }
  if (patch.backendEngine) {
    updates.push(`backend_engine=$${values.length + 1}`);
    values.push(patch.backendEngine);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexModel")) {
    updates.push(`codex_model=$${values.length + 1}`);
    values.push(patch.codexModel ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexModelProvider")) {
    updates.push(`codex_model_provider=$${values.length + 1}`);
    values.push(patch.codexModelProvider ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexApprovalPolicy")) {
    updates.push(`codex_approval_policy=$${values.length + 1}`);
    values.push(patch.codexApprovalPolicy ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexSandbox")) {
    updates.push(`codex_sandbox_json=$${values.length + 1}`);
    values.push(patch.codexSandbox ? JSON.stringify(patch.codexSandbox) : null);
  }

  updates.push(`updated_at=$${values.length + 1}`);
  values.push(new Date().toISOString());
  values.push(projectId);
  values.push(sessionId);

  await ctx.repository.query(
    `UPDATE sessions
     SET ${updates.join(", ")}
     WHERE project_id=$${values.length - 1} AND id=$${values.length}`,
    values
  );

  const sessionRows = await ctx.repository.query<any>(
    `SELECT * FROM sessions
     WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  if (sessionRows.length === 0) {
    throw new Error("Session not found");
  }

  let sessionRow = sessionRows[0];
  const effectiveBackend = normalizeBackendEngine(sessionRow.backend_engine) ?? "codex-app-server";
  const currentThreadId = normalizeNonEmptyString(sessionRow.codex_thread_id);
  const modelProvider = normalizeNonEmptyString(sessionRow.codex_model_provider) ?? DEFAULT_MODEL_PROVIDER;
  const modelId = normalizeNonEmptyString(sessionRow.codex_model);
  const approvalPolicy = normalizeNonEmptyString(sessionRow.codex_approval_policy) ?? DEFAULT_APPROVAL_POLICY;
  const sandbox = safeJsonParseObject(sessionRow.codex_sandbox_json) ?? normalizeSandboxPolicy(null) ?? {};
  const nowIso = new Date().toISOString();

  const mapped = await ensureMappedThreadForSession(ctx, {
    projectId,
    sessionId,
    backendEngine: effectiveBackend,
    currentThreadId,
    modelProvider,
    modelId,
    approvalPolicy,
    sandbox,
  });
  const mappedThread = mapped.thread;

  await ctx.repository.assignThreadToSession({ threadId: mappedThread.id, sessionId });
  if (currentThreadId && currentThreadId !== mappedThread.id) {
    await ctx.repository.assignThreadToSession({ threadId: currentThreadId, sessionId: null });
  }

  await ctx.repository.query(
    `UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`,
    [mappedThread.id, nowIso, sessionId]
  );

  const refreshedRows = await ctx.repository.query<any>(
    `SELECT * FROM sessions
     WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  if (refreshedRows.length > 0) {
    sessionRow = refreshedRows[0];
  }

  return {
    session: mapSessionRow(sessionRow, ctx.pendingUserInputSummaryBySession?.get(sessionId)),
    thread: mappedThread,
  };
}

export async function handleLabosSessionDelete(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  if (!projectId || !sessionId) {
    throw new Error("Missing projectId or sessionId");
  }

  const rows = await ctx.repository.query<any>(
    `SELECT * FROM sessions
     WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  if (rows.length === 0) {
    throw new Error("Session not found");
  }

  await ctx.repository.removeSessionThreadMappings(sessionId);
  await ctx.repository.query(`UPDATE runs SET session_id=NULL WHERE project_id=$1 AND session_id=$2`, [projectId, sessionId]);
  await ctx.repository.query(`DELETE FROM sessions WHERE project_id=$1 AND id=$2`, [projectId, sessionId]);
  await ctx.repository.removeSessionTranscript(projectId, sessionId);

  return {
    ok: true,
    session: mapSessionRow(rows[0], ctx.pendingUserInputSummaryBySession?.get(sessionId)),
  };
}

export async function handleLabosSessionRead(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  const includeTurns = Boolean(params.includeTurns);
  if (!projectId || !sessionId) {
    throw new Error("Missing projectId or sessionId");
  }

  const rows = await ctx.repository.query<any>(
    `SELECT *
     FROM sessions
     WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  if (rows.length === 0) {
    throw new Error("Session not found");
  }

  let sessionRow = rows[0];
  let threadId = normalizeNonEmptyString(sessionRow.codex_thread_id);
  const backendEngine = normalizeBackendEngine(sessionRow.backend_engine) ?? "codex-app-server";
  const modelProvider = normalizeNonEmptyString(sessionRow.codex_model_provider) ?? DEFAULT_MODEL_PROVIDER;
  const modelId = normalizeNonEmptyString(sessionRow.codex_model);
  const approvalPolicy = normalizeNonEmptyString(sessionRow.codex_approval_policy) ?? DEFAULT_APPROVAL_POLICY;
  const sandbox = safeJsonParseObject(sessionRow.codex_sandbox_json) ?? normalizeSandboxPolicy(null) ?? {};
  let syncState: ThreadSyncState | null = null;
  let rehydratedFromLegacy = false;

  if (!threadId || backendEngine === "codex-app-server") {
    const mapped = await ensureMappedThreadForSession(ctx, {
      projectId,
      sessionId,
      backendEngine,
      currentThreadId: threadId,
      modelProvider,
      modelId,
      approvalPolicy,
      sandbox,
    });
    threadId = mapped.thread.id;
    syncState = mapped.syncState;
    rehydratedFromLegacy = mapped.rehydratedFromLegacy;
    await ctx.repository.assignThreadToSession({ threadId, sessionId });

    const previousThreadId = normalizeNonEmptyString(sessionRow.codex_thread_id);
    if (previousThreadId && previousThreadId !== threadId) {
      await ctx.repository.assignThreadToSession({ threadId: previousThreadId, sessionId: null });
    }
    if (!previousThreadId || previousThreadId !== threadId) {
      const nowIso = new Date().toISOString();
      await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [threadId, nowIso, sessionId]);
      sessionRow = {
        ...sessionRow,
        codex_thread_id: threadId,
        updated_at: nowIso,
      };
    }
  }

  let thread: Thread | null = null;
  if (threadId) {
    if (includeTurns) {
      await ctx.repository.reconcileStaleInProgressTurn({
        threadId,
        staleAfterSeconds: STALE_IN_PROGRESS_SECONDS,
      });
    }
    thread = await ctx.repository.readThread(threadId, includeTurns);
  }

  if (includeTurns && threadId && thread && thread.turns.length === 0) {
    const imported = await ctx.repository.backfillThreadFromLegacyMessages({
      threadId,
      projectId,
      sessionId,
    });
    if (imported.imported) {
      rehydratedFromLegacy = true;
      syncState = "needsRemoteHydration";
      await setThreadSyncState(ctx.repository, threadId, syncState);
      thread = await ctx.repository.readThread(threadId, true);
    }
  }

  if (includeTurns && backendEngine === "codex-app-server" && threadId && (!thread || thread.turns.length === 0)) {
    const codexEngine = await ctx.engines.getEngine("codex-app-server");
    if (codexEngine.threadRead) {
      try {
        const proxied = await codexEngine.threadRead({
          threadId,
          includeTurns: true,
        });
        await maybePersistThreadFromResponse(ctx.repository, proxied, "codex-app-server");

        const proxiedThreadRaw = (proxied.thread ?? null) as Record<string, unknown> | null;
        const proxiedThreadId = normalizeNonEmptyString(proxiedThreadRaw?.id);
        if (proxiedThreadId && proxiedThreadId !== threadId) {
          await ctx.repository.assignThreadToSession({ threadId, sessionId: null });
          await ctx.repository.assignThreadToSession({ threadId: proxiedThreadId, sessionId });
          const nowIso = new Date().toISOString();
          await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
            proxiedThreadId,
            nowIso,
            sessionId,
          ]);
          sessionRow = {
            ...sessionRow,
            codex_thread_id: proxiedThreadId,
            updated_at: nowIso,
          };
          threadId = proxiedThreadId;
        }

        syncState = "ready";
        await setThreadSyncState(ctx.repository, threadId, syncState);
        thread = await ctx.repository.readThread(threadId, true);
      } catch {
        syncState = "needsRemoteHydration";
        await setThreadSyncState(ctx.repository, threadId, syncState);
      }
    }
  }

  if (!syncState && threadId) {
    const threadRecord = await ctx.repository.getThreadRecord(threadId);
    syncState = readThreadSyncState(threadRecord?.statusJson) ?? "ready";
  }

  const session = mapSessionRow(sessionRow, ctx.pendingUserInputSummaryBySession?.get(sessionId));
  const pendingInputs = await ctx.repository.listPendingInputsForSession({
    sessionId,
    token: ctx.runtimeToken ?? null,
  });
  const activePlan = await ctx.repository.readPlanSnapshotForSession({
    sessionId,
    token: ctx.runtimeToken ?? null,
  });
  const response: Record<string, unknown> = {
    session,
    thread,
    pendingUserInputs: pendingInputs.map((entry) => ({
      requestId: entry.requestId,
      method: entry.method,
      kind: entry.kind,
      params: entry.params,
      createdAt: entry.createdAt,
    })),
  };
  if (activePlan && activePlan.plan.length > 0) {
    response.activePlan = {
      turnId: activePlan.turnId,
      explanation: activePlan.explanation,
      plan: activePlan.plan,
      updatedAt: activePlan.updatedAt,
    };
  }
  if (rehydratedFromLegacy) {
    response.rehydratedFromLegacy = true;
  }
  if (syncState) {
    response.syncState = syncState;
  }
  return response;
}

export async function handleLabosSessionRegenerate(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<{
  threadId: string;
  input: UserInput[];
  targetTurnId: string;
  rolledBackTurns: number;
}> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const sessionId = normalizeNonEmptyString(params.sessionId);
  const assistantItemId = normalizeNonEmptyString(params.assistantItemId);
  const assistantText = normalizeNonEmptyString(params.assistantText);
  if (!projectId || !sessionId || !assistantItemId) {
    throw new Error("Missing projectId, sessionId, or assistantItemId");
  }

  const rows = await ctx.repository.query<any>(
    `SELECT *
     FROM sessions
     WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  if (rows.length === 0) {
    throw new Error("Session not found");
  }
  const sessionRow = rows[0];

  let threadId = normalizeNonEmptyString(sessionRow.codex_thread_id);
  const backendEngine = normalizeBackendEngine(sessionRow.backend_engine) ?? "codex-app-server";
  const modelProvider = normalizeNonEmptyString(sessionRow.codex_model_provider) ?? DEFAULT_MODEL_PROVIDER;
  const modelId = normalizeNonEmptyString(sessionRow.codex_model);
  const approvalPolicy = normalizeNonEmptyString(sessionRow.codex_approval_policy) ?? DEFAULT_APPROVAL_POLICY;
  const sandbox = safeJsonParseObject(sessionRow.codex_sandbox_json) ?? normalizeSandboxPolicy(null) ?? {};

  if (!threadId || backendEngine === "codex-app-server") {
    const mapped = await ensureMappedThreadForSession(ctx, {
      projectId,
      sessionId,
      backendEngine,
      currentThreadId: threadId,
      modelProvider,
      modelId,
      approvalPolicy,
      sandbox,
    });
    threadId = mapped.thread.id;
    await ctx.repository.assignThreadToSession({ threadId, sessionId });
    if (threadId !== normalizeNonEmptyString(sessionRow.codex_thread_id)) {
      await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
        threadId,
        new Date().toISOString(),
        sessionId,
      ]);
    }
  }

  if (!threadId) {
    throw new Error("Session is missing thread mapping");
  }

  let thread = await ctx.repository.readThread(threadId, true);
  if (!thread) {
    throw new Error("Thread not found");
  }
  if (thread.turns.length === 0) {
    const imported = await ctx.repository.backfillThreadFromLegacyMessages({
      threadId,
      projectId,
      sessionId,
    });
    if (imported.imported) {
      thread = await ctx.repository.readThread(threadId, true);
    }
  }
  if (!thread || thread.turns.length === 0) {
    throw new Error("No turn history available for regenerate");
  }

  const targetTurnIndex = findTargetRegenerateTurnIndex(thread, assistantItemId, assistantText);
  if (targetTurnIndex < 0) {
    throw new Error("Unable to find selected assistant message in thread history");
  }

  const targetTurn = thread.turns[targetTurnIndex];
  const sourceInput = resolveRegenerateSourceInput({
    targetTurn,
    assistantItemId,
    priorTurns: thread.turns.slice(0, targetTurnIndex),
  });
  if (sourceInput.length === 0) {
    throw new Error("Unable to resolve source input for regenerate");
  }

  const rolledBackTurns = Math.max(0, thread.turns.length - targetTurnIndex);
  if (rolledBackTurns > 0) {
    const rollbackResult = await handleThreadRollback(
      {
        repository: ctx.repository,
        engines: ctx.engines,
      },
      {
        threadId,
        numTurns: rolledBackTurns,
      }
    );
    const rollbackThreadRaw = (rollbackResult.thread ?? null) as Record<string, unknown> | null;
    const rollbackThreadId = normalizeNonEmptyString(rollbackThreadRaw?.id);
    if (rollbackThreadId && rollbackThreadId !== threadId) {
      await ctx.repository.assignThreadToSession({ threadId, sessionId: null });
      await ctx.repository.assignThreadToSession({ threadId: rollbackThreadId, sessionId });
      await ctx.repository.query(`UPDATE sessions SET codex_thread_id=$1, updated_at=$2 WHERE id=$3`, [
        rollbackThreadId,
        new Date().toISOString(),
        sessionId,
      ]);
      threadId = rollbackThreadId;
    }
  }

  return {
    threadId,
    input: sourceInput,
    targetTurnId: targetTurn.id,
    rolledBackTurns,
  };
}

export async function handleLabosArtifactList(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  if (!projectId) {
    throw new Error("Missing projectId");
  }
  const limit = Math.max(1, Math.min(500, Number(params.limit ?? 200) || 200));
  const rows = await ctx.repository.query<any>(
    `SELECT *
     FROM artifacts
     WHERE project_id=$1
     ORDER BY modified_at DESC, path ASC
     LIMIT $2`,
    [projectId, limit]
  );

  return {
    artifacts: rows.map((row) => mapArtifactRow(row)),
  };
}

export async function handleLabosArtifactGet(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const pathValue = normalizeNonEmptyString(params.path);
  if (!projectId || !pathValue) {
    throw new Error("Missing projectId or path");
  }

  const rows = await ctx.repository.query<any>(
    `SELECT *
     FROM artifacts
     WHERE project_id=$1 AND path=$2
     LIMIT 1`,
    [projectId, pathValue]
  );
  if (rows.length === 0) {
    throw new Error("Artifact not found");
  }

  return {
    artifact: mapArtifactRow(rows[0]),
  };
}

export async function handleLabosRunList(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  if (!projectId) {
    throw new Error("Missing projectId");
  }
  const sessionId = normalizeNonEmptyString(params.sessionId);
  const limit = Math.max(1, Math.min(500, Number(params.limit ?? 200) || 200));
  const rows = await ctx.repository.query<any>(
    sessionId
      ? `SELECT *
         FROM runs
         WHERE project_id=$1 AND session_id=$2
         ORDER BY initiated_at DESC, id DESC
         LIMIT $3`
      : `SELECT *
         FROM runs
         WHERE project_id=$1
         ORDER BY initiated_at DESC, id DESC
         LIMIT $2`,
    sessionId ? [projectId, sessionId, limit] : [projectId, limit]
  );

  return {
    runs: rows.map((row) => mapRunRow(row)),
  };
}

export async function handleLabosRunGet(
  ctx: LabosHandlerContext,
  rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  const params = rawParams ?? {};
  const projectId = normalizeNonEmptyString(params.projectId);
  const runId = normalizeNonEmptyString(params.runId);
  if (!projectId || !runId) {
    throw new Error("Missing projectId or runId");
  }

  const rows = await ctx.repository.query<any>(
    `SELECT *
     FROM runs
     WHERE project_id=$1 AND id=$2
     LIMIT 1`,
    [projectId, runId]
  );
  if (rows.length === 0) {
    throw new Error("Run not found");
  }

  return {
    run: mapRunRow(rows[0]),
  };
}

export async function handleLabosHpcPrefsSet(
  _ctx: LabosHandlerContext,
  _rawParams: Record<string, unknown> | undefined
): Promise<Record<string, unknown>> {
  // Preferences are still owned by the legacy node connection in v0.1.
  // Expose a no-op codex extension method to keep `/codex` project/session flows self-contained.
  return { ok: true };
}

function mapProjectRow(row: any) {
  return {
    id: String(row.id),
    name: String(row.name ?? "Untitled Project"),
    createdAt: toIso(row.created_at),
    updatedAt: toIso(row.updated_at),
    backendEngine: normalizeBackendEngine(row.backend_engine) ?? "codex-app-server",
    codexModelProvider: normalizeNonEmptyString(row.codex_model_provider),
    codexModel: normalizeNonEmptyString(row.codex_model_id),
    codexApprovalPolicy: normalizeNonEmptyString(row.codex_approval_policy),
    codexSandbox: safeJsonParseObject(row.codex_sandbox_json),
    hpcWorkspacePath: normalizeNonEmptyString(row.hpc_workspace_path),
    hpcWorkspaceState: normalizeNonEmptyString(row.hpc_workspace_state) ?? "queued",
  };
}

function mapSessionRow(row: any, pendingSummary?: { count: number; kind: string | null }) {
  const pendingCount = Math.max(0, Number(pendingSummary?.count ?? 0) || 0);
  return {
    id: String(row.id),
    projectID: String(row.project_id),
    title: String(row.title ?? ""),
    lifecycle: String(row.lifecycle ?? "active"),
    createdAt: toIso(row.created_at),
    updatedAt: toIso(row.updated_at),
    backendEngine: normalizeBackendEngine(row.backend_engine) ?? "codex-app-server",
    codexThreadId: normalizeNonEmptyString(row.codex_thread_id),
    codexModel: normalizeNonEmptyString(row.codex_model),
    codexModelProvider: normalizeNonEmptyString(row.codex_model_provider),
    codexApprovalPolicy: normalizeNonEmptyString(row.codex_approval_policy),
    codexSandbox: safeJsonParseObject(row.codex_sandbox_json),
    hpcWorkspaceState: normalizeNonEmptyString(row.hpc_workspace_state),
    hasPendingUserInput: pendingCount > 0,
    pendingUserInputCount: pendingCount,
    pendingUserInputKind: pendingSummary?.kind ?? null,
  };
}

function mapArtifactRow(row: any) {
  return {
    id: String(row.id),
    projectID: String(row.project_id),
    path: String(row.path ?? ""),
    kind: String(row.kind ?? "unknown"),
    origin: String(row.origin ?? "generated"),
    modifiedAt: toIso(row.modified_at),
    sizeBytes: row.size_bytes == null ? null : Number(row.size_bytes),
    createdBySessionID: row.created_by_session_id == null ? null : String(row.created_by_session_id),
    createdByRunID: row.created_by_run_id == null ? null : String(row.created_by_run_id),
  };
}

function mapRunRow(row: any) {
  return {
    id: String(row.id),
    projectID: String(row.project_id),
    sessionID: row.session_id == null ? null : String(row.session_id),
    status: String(row.status ?? "queued"),
    initiatedAt: toIso(row.initiated_at),
    completedAt: row.completed_at == null ? null : toIso(row.completed_at),
    currentStep: Number(row.current_step ?? 0),
    totalSteps: Number(row.total_steps ?? 0),
    logSnippet: String(row.log_snippet ?? ""),
    stepTitles: safeJsonParseStringArray(row.step_titles),
    producedArtifactPaths: safeJsonParseStringArray(row.produced_artifact_paths),
    hpcJobId: row.hpc_job_id == null ? null : String(row.hpc_job_id),
    permissionLevel: normalizeNonEmptyString(row.permission_level) ?? "default",
  };
}

async function createMappedThreadForSession(
  repository: CodexRepository,
  engines: CodexEngineRegistry,
  args: {
    sessionId: string;
    projectId: string;
    backendEngine: "codex-app-server";
    modelProvider: string;
    modelId: string | null;
    approvalPolicy: string;
    sandbox: Record<string, unknown>;
  }
): Promise<Thread> {
  const cwd = resolveProjectWorkspacePath(args.projectId);
  const status = {
    modelProvider: args.modelProvider,
    model: args.modelId,
    cwd,
    approvalPolicy: args.approvalPolicy,
    sandbox: args.sandbox,
    reasoningEffort: null,
    syncState: "ready",
  };

  const engine = await engines.getEngine("codex-app-server");
  if (!engine.threadStart) {
    throw new Error("Codex app-server engine does not support thread/start.");
  }
  const sandboxMode = toCodexSandboxMode(args.sandbox);

  const proxied = await engine.threadStart({
    cwd,
    modelProvider: args.modelProvider,
    ...(args.modelId ? { model: args.modelId } : {}),
    approvalPolicy: args.approvalPolicy,
    ...(sandboxMode ? { sandbox: sandboxMode } : {}),
  });

  const threadRaw = (proxied.thread ?? null) as Record<string, unknown> | null;
  const threadId = normalizeNonEmptyString(threadRaw?.id);
  if (!threadId) {
    throw new Error("Codex app-server did not return thread.id.");
  }

  const createdAt = Number(threadRaw?.createdAt ?? nowUnixSeconds());
  const resolvedCwd = normalizeNonEmptyString(threadRaw?.cwd) ?? cwd;
  const modelProvider = normalizeNonEmptyString(threadRaw?.modelProvider) ?? args.modelProvider;
  const preview = normalizeNonEmptyString(threadRaw?.preview) ?? "";
  const statusJson = JSON.stringify({
    ...status,
    cwd: resolvedCwd,
    modelProvider,
  });

  const existing = await repository.getThreadRecord(threadId);
  if (!existing) {
    await repository.createThread({
      id: threadId,
      projectId: args.projectId,
      cwd: resolvedCwd,
      modelProvider,
      modelId: args.modelId,
      preview,
      statusJson,
      engine: "codex-app-server",
      createdAt,
    });
  } else {
    await repository.updateThread({
      id: threadId,
      cwd: resolvedCwd,
      modelProvider,
      modelId: args.modelId,
      preview,
      statusJson,
      engine: "codex-app-server",
    });
  }

  await repository.assignThreadToSession({ threadId, sessionId: args.sessionId });

  return {
    id: threadId,
    preview,
    modelProvider,
    createdAt,
    updatedAt: createdAt,
    path: null,
    cwd: resolvedCwd,
    cliVersion: "@labos/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };
}

async function ensureMappedThreadForSession(
  ctx: LabosHandlerContext,
  args: {
    projectId: string;
    sessionId: string;
    backendEngine: "codex-app-server";
    currentThreadId: string | null;
    modelProvider: string;
    modelId: string | null;
    approvalPolicy: string;
    sandbox: Record<string, unknown>;
  }
): Promise<EnsureMappedThreadResult> {
  const settings = {
    modelProvider: args.modelProvider,
    model: args.modelId,
    cwd: resolveProjectWorkspacePath(args.projectId),
    approvalPolicy: args.approvalPolicy,
    sandbox: args.sandbox,
    reasoningEffort: null,
    syncState: "ready",
  };

  if (args.currentThreadId) {
    const existing = await ctx.repository.getThreadRecord(args.currentThreadId);
    if (existing?.engine === "codex-app-server" && isValidCodexAppServerThreadId(existing.id)) {
      const syncState = readThreadSyncState(existing.statusJson) ?? "ready";
      await ctx.repository.updateThread({
        id: existing.id,
        modelProvider: args.modelProvider,
        modelId: args.modelId,
        cwd: settings.cwd,
        statusJson: applyThreadSyncState(JSON.stringify(settings), syncState),
        engine: "codex-app-server",
        updatedAt: nowUnixSeconds(),
      });
      const thread = await ctx.repository.readThread(existing.id, true);
      if (thread) {
        return {
          thread,
          syncState,
          rehydratedFromLegacy: false,
        };
      }
    }
  }

  const created = await createMappedThreadForSession(ctx.repository, ctx.engines, {
    sessionId: args.sessionId,
    projectId: args.projectId,
    backendEngine: "codex-app-server",
    modelProvider: args.modelProvider,
    modelId: args.modelId,
    approvalPolicy: args.approvalPolicy,
    sandbox: args.sandbox,
  });

  let rehydratedFromLegacy = false;
  const history = await buildSessionHistoryForCodex(ctx.repository, args.projectId, args.sessionId, args.currentThreadId);
  if (history.length === 0) {
    return {
      thread: created,
      syncState: "ready",
      rehydratedFromLegacy: false,
    };
  }

  const codexEngine = await ctx.engines.getEngine("codex-app-server");
  if (!codexEngine.threadResume) {
    const imported = await ctx.repository.backfillThreadFromLegacyMessages({
      threadId: created.id,
      projectId: args.projectId,
      sessionId: args.sessionId,
    });
    rehydratedFromLegacy = imported.imported;
    await setThreadSyncState(ctx.repository, created.id, "needsRemoteHydration");
    const localThread = await ctx.repository.readThread(created.id, true);
    return {
      thread: localThread ?? created,
      syncState: "needsRemoteHydration",
      rehydratedFromLegacy,
    };
  }

  const sandboxMode = toCodexSandboxMode(args.sandbox);
  let resumed: Record<string, unknown>;
  try {
    resumed = await codexEngine.threadResume({
      threadId: created.id,
      history,
      cwd: settings.cwd,
      modelProvider: args.modelProvider,
      ...(args.modelId ? { model: args.modelId } : {}),
      approvalPolicy: args.approvalPolicy,
      ...(sandboxMode ? { sandbox: sandboxMode } : {}),
    });
  } catch {
    const imported = await ctx.repository.backfillThreadFromLegacyMessages({
      threadId: created.id,
      projectId: args.projectId,
      sessionId: args.sessionId,
    });
    rehydratedFromLegacy = imported.imported;
    await setThreadSyncState(ctx.repository, created.id, "needsRemoteHydration");
    const localThread = await ctx.repository.readThread(created.id, true);
    return {
      thread: localThread ?? created,
      syncState: "needsRemoteHydration",
      rehydratedFromLegacy,
    };
  }
  await maybePersistThreadFromResponse(ctx.repository, resumed, "codex-app-server");

  const resumedThreadRaw = (resumed.thread ?? null) as Record<string, unknown> | null;
  const resumedThreadId = normalizeNonEmptyString(resumedThreadRaw?.id);
  if (!resumedThreadId) {
    const imported = await ctx.repository.backfillThreadFromLegacyMessages({
      threadId: created.id,
      projectId: args.projectId,
      sessionId: args.sessionId,
    });
    rehydratedFromLegacy = imported.imported;
    await setThreadSyncState(ctx.repository, created.id, "needsRemoteHydration");
    const localThread = await ctx.repository.readThread(created.id, true);
    return {
      thread: localThread ?? created,
      syncState: "needsRemoteHydration",
      rehydratedFromLegacy,
    };
  }

  if (resumedThreadId !== created.id) {
    await ctx.repository.assignThreadToSession({ threadId: created.id, sessionId: null });
  }

  const persisted = await ctx.repository.getThreadRecord(resumedThreadId);
  if (!persisted) {
    const createdAt = Number(resumedThreadRaw?.createdAt ?? nowUnixSeconds());
    await ctx.repository.createThread({
      id: resumedThreadId,
      projectId: args.projectId,
      cwd: normalizeNonEmptyString(resumedThreadRaw?.cwd) ?? settings.cwd,
      modelProvider: normalizeNonEmptyString(resumedThreadRaw?.modelProvider) ?? args.modelProvider,
      modelId: args.modelId,
      preview: normalizeNonEmptyString(resumedThreadRaw?.preview) ?? "",
      statusJson: applyThreadSyncState(JSON.stringify(settings), "ready"),
      engine: "codex-app-server",
      createdAt,
    });
  } else {
    await ctx.repository.updateThread({
      id: resumedThreadId,
      modelProvider: args.modelProvider,
      modelId: args.modelId,
      cwd: settings.cwd,
      statusJson: applyThreadSyncState(JSON.stringify(settings), "ready"),
      engine: "codex-app-server",
      updatedAt: nowUnixSeconds(),
    });
  }

  const thread = await ctx.repository.readThread(resumedThreadId, true);
  return {
    thread:
      thread ?? {
        ...created,
        id: resumedThreadId,
      },
    syncState: "ready",
    rehydratedFromLegacy,
  };
}

function isValidCodexAppServerThreadId(threadId: string): boolean {
  return CODEX_APP_SERVER_THREAD_ID_RE.test(threadId);
}

async function buildSessionHistoryForCodex(
  repository: CodexRepository,
  projectId: string,
  sessionId: string,
  currentThreadId: string | null
): Promise<Array<Record<string, unknown>>> {
  if (currentThreadId) {
    const thread = await repository.readThread(currentThreadId, true);
    if (thread && thread.turns.length > 0) {
      const fromThread = responseHistoryFromThread(thread);
      if (fromThread.length > 0) return fromThread;
    }
  }
  return await responseHistoryFromLegacyMessages(repository, projectId, sessionId);
}

function responseHistoryFromThread(thread: Thread): Array<Record<string, unknown>> {
  const history: Array<Record<string, unknown>> = [];
  for (const turn of thread.turns) {
    for (const item of turn.items) {
      appendResponseItemsFromThreadItem(history, item);
    }
  }
  return history;
}

function appendResponseItemsFromThreadItem(history: Array<Record<string, unknown>>, item: ThreadItem) {
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

  if (item.type === "agentMessage") {
    const text = String(item.text ?? "").trim();
    if (!text) return;
    history.push({
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text }],
      end_turn: true,
    });
    return;
  }

  if (item.type === "plan") {
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

async function responseHistoryFromLegacyMessages(
  repository: CodexRepository,
  projectId: string,
  sessionId: string
): Promise<Array<Record<string, unknown>>> {
  const rows = await repository.query<any>(
    `SELECT role, content
     FROM messages
     WHERE project_id=$1 AND session_id=$2
     ORDER BY ts ASC, id ASC`,
    [projectId, sessionId]
  );

  const history: Array<Record<string, unknown>> = [];
  for (const row of rows) {
    const role = normalizeNonEmptyString(row.role)?.toLowerCase() ?? "";
    const contentText = String(row.content ?? "").trim();
    if (!contentText) continue;
    if (role === "user") {
      history.push({
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: contentText }],
        end_turn: true,
      });
      continue;
    }
    if (role === "assistant" || role === "system") {
      history.push({
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: contentText }],
        end_turn: true,
      });
    }
  }
  return history;
}

async function setThreadSyncState(repository: CodexRepository, threadId: string, syncState: ThreadSyncState) {
  const record = await repository.getThreadRecord(threadId);
  if (!record) return;
  await repository.updateThread({
    id: threadId,
    statusJson: applyThreadSyncState(record.statusJson, syncState),
    updatedAt: nowUnixSeconds(),
  });
}

function readThreadSyncState(rawStatusJson: string | null | undefined): ThreadSyncState | null {
  if (!rawStatusJson) return null;
  try {
    const parsed = JSON.parse(rawStatusJson);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    const value = normalizeNonEmptyString((parsed as Record<string, unknown>).syncState);
    if (value === "needsRemoteHydration") return "needsRemoteHydration";
    if (value === "ready") return "ready";
    return null;
  } catch {
    return null;
  }
}

function applyThreadSyncState(rawStatusJson: string | null | undefined, syncState: ThreadSyncState): string {
  const base = safeJsonParseObject(rawStatusJson) ?? {};
  return JSON.stringify({
    ...base,
    syncState,
  });
}

function findTargetRegenerateTurnIndex(thread: Thread, assistantItemId: string, assistantText: string | null): number {
  const normalizedItemId = assistantItemId.trim();
  const normalizedText = normalizeAssistantRegenerateText(assistantText);
  for (let i = thread.turns.length - 1; i >= 0; i -= 1) {
    const turn = thread.turns[i];
    if (turn.items.some((item) => item.type === "agentMessage" && String(item.id).trim() === normalizedItemId)) {
      return i;
    }
  }

  if (normalizedText) {
    for (let i = thread.turns.length - 1; i >= 0; i -= 1) {
      const turn = thread.turns[i];
      const matchesText = turn.items.some((item) => {
        if (item.type !== "agentMessage") return false;
        const candidate = normalizeAssistantRegenerateText(String(item.text ?? ""));
        if (!candidate) return false;
        return candidate === normalizedText || candidate.includes(normalizedText) || normalizedText.includes(candidate);
      });
      if (matchesText) return i;
    }
  }

  for (let i = thread.turns.length - 1; i >= 0; i -= 1) {
    const turn = thread.turns[i];
    if (turn.items.some((item) => item.type === "agentMessage" && normalizeNonEmptyString(item.text) != null)) {
      return i;
    }
  }

  return -1;
}

function resolveRegenerateSourceInput(args: {
  targetTurn: Turn;
  assistantItemId: string;
  priorTurns: Turn[];
}): UserInput[] {
  let mostRecentUserInput: UserInput[] | null = null;

  for (const item of args.targetTurn.items) {
    if (item.type === "userMessage" && Array.isArray(item.content) && item.content.length > 0) {
      mostRecentUserInput = cloneUserInputs(item.content);
      continue;
    }
    if (item.type === "agentMessage" && String(item.id).trim() === args.assistantItemId && mostRecentUserInput?.length) {
      return mostRecentUserInput;
    }
  }

  if (mostRecentUserInput?.length) {
    return mostRecentUserInput;
  }

  for (let i = args.priorTurns.length - 1; i >= 0; i -= 1) {
    const turn = args.priorTurns[i];
    for (let j = turn.items.length - 1; j >= 0; j -= 1) {
      const item = turn.items[j];
      if (item.type === "userMessage" && Array.isArray(item.content) && item.content.length > 0) {
        return cloneUserInputs(item.content);
      }
    }
  }

  return [];
}

function cloneUserInputs(input: UserInput[]): UserInput[] {
  return input.map((part) => ({ ...part }));
}

function normalizeAssistantRegenerateText(raw: unknown): string | null {
  const value = normalizeNonEmptyString(raw);
  if (!value) return null;
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

async function ensureBootstrapDefaults(stateDir: string, projectId: string) {
  const bootstrapRoot = path.join(stateDir, "projects", projectId, "bootstrap");
  await mkdir(bootstrapRoot, { recursive: true });

  const agentsPath = path.join(bootstrapRoot, "AGENTS.md");
  const readmePath = path.join(bootstrapRoot, "README.md");
  const defaultAgents = [
    "# AGENTS.md",
    "",
    "- This workspace is managed by LabOS Hub.",
    "- Session memory is recorded in per-session transcript JSONL files.",
    "- Use project uploads and indexed snippets as retrieval context before broad web/tool calls.",
    "",
  ].join("\n");
  const defaultReadme = [
    "# Bootstrap Context",
    "",
    "Add project-specific instructions and reusable context files in this folder.",
    "",
  ].join("\n");

  await appendFile(agentsPath, "", { encoding: "utf8", flag: "a" });
  await appendFile(readmePath, "", { encoding: "utf8", flag: "a" });

  // When files are empty, seed them with helpful defaults.
  try {
    if ((await stat(agentsPath)).size === 0) {
      await writeFile(agentsPath, defaultAgents, "utf8");
    }
    if ((await stat(readmePath)).size === 0) {
      await writeFile(readmePath, defaultReadme, "utf8");
    }
  } catch {
    // best effort
  }
}

async function ensureSessionTranscript(stateDir: string, projectId: string, sessionId: string) {
  const transcriptPath = path.join(stateDir, "projects", projectId, "sessions", `${sessionId}.jsonl`);
  await mkdir(path.dirname(transcriptPath), { recursive: true });
  await appendFile(transcriptPath, "", "utf8");
}

async function enqueueWorkspaceProvisioning(
  repository: CodexRepository,
  args: { projectId: string; workspacePath: string; requestedBy: string }
) {
  const nowIso = new Date().toISOString();
  await repository.query(
    `INSERT INTO workspace_provisioning_queue (
       project_id, workspace_path, status, attempts, last_error, requested_by, created_at, updated_at
     ) VALUES ($1,$2,'queued',0,NULL,$3,$4,$4)`,
    [args.projectId, args.workspacePath, args.requestedBy, nowIso]
  );
}

function resolveProjectWorkspacePath(projectId: string): string {
  const root = normalizeNonEmptyString(process.env.LABOS_HPC_WORKSPACE_ROOT);
  if (root) {
    return path.join(root, "projects", projectId);
  }
  return path.join("projects", projectId);
}

function normalizeBackendEngine(raw: unknown): "codex-app-server" | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  if (value === "pi" || value === "pi-adapter") return "codex-app-server";
  if (value === "codex" || value === "codex-app-server") return "codex-app-server";
  return null;
}

function normalizeLifecycle(raw: unknown): "active" | "archived" | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  if (value === "active" || value === "archived") return value;
  return null;
}

function normalizeSandboxPolicy(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    if (raw == null) {
      return {
        mode: "workspace-write",
        networkAccess: true,
        excludeTmpdirEnvVar: false,
        excludeHomeEnvVar: false,
        writableRoots: [],
      };
    }
    return null;
  }

  const mode = normalizeNonEmptyString((raw as Record<string, unknown>).mode) ?? "workspace-write";
  const networkAccess = Boolean((raw as Record<string, unknown>).networkAccess ?? true);
  const excludeTmpdirEnvVar = Boolean((raw as Record<string, unknown>).excludeTmpdirEnvVar ?? false);
  const excludeHomeEnvVar = Boolean((raw as Record<string, unknown>).excludeHomeEnvVar ?? false);
  const writableRoots = Array.isArray((raw as Record<string, unknown>).writableRoots)
    ? ((raw as Record<string, unknown>).writableRoots as unknown[]).map((entry) => String(entry)).filter(Boolean)
    : [];

  return {
    mode,
    networkAccess,
    excludeTmpdirEnvVar,
    excludeHomeEnvVar,
    writableRoots,
  };
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

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function toIso(raw: unknown): string {
  const parsed = Date.parse(String(raw ?? ""));
  if (!Number.isFinite(parsed)) {
    return new Date().toISOString();
  }
  return new Date(parsed).toISOString();
}

function safeJsonParseObject(raw: unknown): Record<string, unknown> | null {
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

function safeJsonParseStringArray(raw: unknown): string[] {
  if (Array.isArray(raw)) {
    return raw.map((entry) => String(entry)).filter(Boolean);
  }
  if (typeof raw !== "string") return [];
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.map((entry) => String(entry)).filter(Boolean);
  } catch {
    return [];
  }
}
