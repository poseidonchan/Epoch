import { appendFile, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";

import type { DbPool } from "../db/db.js";
import { ensureProjectDirs, projectDir, sessionTranscriptPath, threadTranscriptPath } from "../storage/layout.js";
import { nowUnixSeconds, type Thread, type ThreadItem, type Turn, type TurnError, type TurnStatus } from "./types.js";

export type CodexThreadRecord = {
  id: string;
  projectId: string | null;
  cwd: string;
  modelProvider: string;
  modelId: string | null;
  preview: string;
  createdAt: number;
  updatedAt: number;
  archived: boolean;
  statusJson: string | null;
  engine: string;
};

type CodexTurnRecord = {
  id: string;
  threadId: string;
  status: TurnStatus;
  errorJson: string | null;
  createdAt: number;
  completedAt: number | null;
};

type CodexItemRecord = {
  id: string;
  threadId: string;
  turnId: string;
  type: string;
  payloadJson: string;
  createdAt: number;
  updatedAt: number;
};

export class CodexRepository {
  private readonly pool: DbPool;
  private readonly stateDir: string;

  constructor(opts: { pool: DbPool; stateDir: string }) {
    this.pool = opts.pool;
    this.stateDir = opts.stateDir;
  }

  stateDirectory(): string {
    return this.stateDir;
  }

  dbPool(): DbPool {
    return this.pool;
  }

  async query<T = any>(sql: string, params: unknown[] = []): Promise<T[]> {
    const res = await this.pool.query<T>(sql, params as any[]);
    return res.rows as T[];
  }

  async ensureProjectStorage(projectId: string) {
    await ensureProjectDirs({ stateDir: this.stateDir }, projectId);
  }

  async createThread(args: {
    id: string;
    projectId: string | null;
    cwd: string;
    modelProvider: string;
    modelId: string | null;
    preview: string;
    statusJson: string | null;
    engine: string;
    createdAt?: number;
  }): Promise<CodexThreadRecord> {
    const createdAt = args.createdAt ?? nowUnixSeconds();
    await this.pool.query(
      `INSERT INTO threads (id, project_id, cwd, model_provider, model_id, preview, created_at, updated_at, archived, status_json, engine)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,0,$9,$10)`,
      [
        args.id,
        args.projectId,
        args.cwd,
        args.modelProvider,
        args.modelId,
        args.preview,
        createdAt,
        createdAt,
        args.statusJson,
        args.engine,
      ]
    );
    return {
      id: args.id,
      projectId: args.projectId,
      cwd: args.cwd,
      modelProvider: args.modelProvider,
      modelId: args.modelId,
      preview: args.preview,
      createdAt,
      updatedAt: createdAt,
      archived: false,
      statusJson: args.statusJson,
      engine: args.engine,
    };
  }

  async updateThread(args: {
    id: string;
    preview?: string;
    modelProvider?: string;
    modelId?: string | null;
    cwd?: string;
    archived?: boolean;
    statusJson?: string | null;
    engine?: string;
    updatedAt?: number;
  }) {
    const updates: string[] = [];
    const params: unknown[] = [];
    let index = 1;

    if (args.preview != null) {
      updates.push(`preview=$${index++}`);
      params.push(args.preview);
    }
    if (args.modelProvider != null) {
      updates.push(`model_provider=$${index++}`);
      params.push(args.modelProvider);
    }
    if (Object.prototype.hasOwnProperty.call(args, "modelId")) {
      updates.push(`model_id=$${index++}`);
      params.push(args.modelId ?? null);
    }
    if (args.cwd != null) {
      updates.push(`cwd=$${index++}`);
      params.push(args.cwd);
    }
    if (args.archived != null) {
      updates.push(`archived=$${index++}`);
      params.push(args.archived ? 1 : 0);
    }
    if (Object.prototype.hasOwnProperty.call(args, "statusJson")) {
      updates.push(`status_json=$${index++}`);
      params.push(args.statusJson ?? null);
    }
    if (args.engine != null) {
      updates.push(`engine=$${index++}`);
      params.push(args.engine);
    }

    updates.push(`updated_at=$${index++}`);
    params.push(args.updatedAt ?? nowUnixSeconds());

    params.push(args.id);

    await this.pool.query(`UPDATE threads SET ${updates.join(", ")} WHERE id=$${index}`, params as any[]);
  }

  async getThreadRecord(threadId: string): Promise<CodexThreadRecord | null> {
    const result = await this.pool.query<any>(
      `SELECT id, project_id, cwd, model_provider, model_id, preview, created_at, updated_at, archived, status_json, engine
       FROM threads WHERE id=$1`,
      [threadId]
    );
    if (result.rows.length === 0) return null;
    return mapThreadRow(result.rows[0]);
  }

  async listThreadRecords(opts: {
    cwd?: string | null;
    archived?: boolean | null;
    modelProviders?: string[] | null;
    limit?: number | null;
  }): Promise<CodexThreadRecord[]> {
    const conditions: string[] = [];
    const params: unknown[] = [];

    if (opts.cwd && opts.cwd.trim()) {
      params.push(opts.cwd.trim());
      conditions.push(`cwd=$${params.length}`);
    }

    if (opts.archived === true) {
      conditions.push("archived=1");
    } else {
      // Default matches Codex behavior: only active threads unless archived=true is requested.
      conditions.push("archived=0");
    }

    if (Array.isArray(opts.modelProviders) && opts.modelProviders.length > 0) {
      const normalized = opts.modelProviders.map((provider) => String(provider).trim()).filter(Boolean);
      if (normalized.length > 0) {
        const placeholders: string[] = [];
        for (const provider of normalized) {
          params.push(provider);
          placeholders.push(`$${params.length}`);
        }
        conditions.push(`model_provider IN (${placeholders.join(",")})`);
      }
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
    const limit = Math.min(200, Math.max(1, Number(opts.limit ?? 50) || 50));
    params.push(limit);

    const result = await this.pool.query<any>(
      `SELECT id, project_id, cwd, model_provider, model_id, preview, created_at, updated_at, archived, status_json, engine
       FROM threads
       ${where}
       ORDER BY updated_at DESC, id DESC
       LIMIT $${params.length}`,
      params as any[]
    );

    return result.rows.map((row: any) => mapThreadRow(row));
  }

  async createTurn(args: {
    id: string;
    threadId: string;
    status: TurnStatus;
    error: TurnError | null;
    createdAt?: number;
  }): Promise<CodexTurnRecord> {
    const createdAt = args.createdAt ?? nowUnixSeconds();
    await this.pool.query(
      `INSERT INTO turns (id, thread_id, status, error_json, created_at, completed_at)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [args.id, args.threadId, args.status, args.error ? JSON.stringify(args.error) : null, createdAt, null]
    );
    await this.updateThread({ id: args.threadId, updatedAt: createdAt });
    return {
      id: args.id,
      threadId: args.threadId,
      status: args.status,
      errorJson: args.error ? JSON.stringify(args.error) : null,
      createdAt,
      completedAt: null,
    };
  }

  async updateTurn(args: {
    id: string;
    status?: TurnStatus;
    error?: TurnError | null;
    completedAt?: number | null;
    touchThreadId?: string;
  }) {
    const updates: string[] = [];
    const params: unknown[] = [];
    let index = 1;

    if (args.status) {
      updates.push(`status=$${index++}`);
      params.push(args.status);
    }
    if (Object.prototype.hasOwnProperty.call(args, "error")) {
      updates.push(`error_json=$${index++}`);
      params.push(args.error ? JSON.stringify(args.error) : null);
    }
    if (Object.prototype.hasOwnProperty.call(args, "completedAt")) {
      updates.push(`completed_at=$${index++}`);
      params.push(args.completedAt ?? null);
    }

    if (updates.length > 0) {
      params.push(args.id);
      await this.pool.query(`UPDATE turns SET ${updates.join(", ")} WHERE id=$${index}`, params as any[]);
    }

    if (args.touchThreadId) {
      await this.updateThread({ id: args.touchThreadId, updatedAt: nowUnixSeconds() });
    }
  }

  async listTurnRecords(threadId: string): Promise<CodexTurnRecord[]> {
    const result = await this.pool.query<any>(
      `SELECT id, thread_id, status, error_json, created_at, completed_at
       FROM turns
       WHERE thread_id=$1
       ORDER BY created_at ASC, id ASC`,
      [threadId]
    );
    return result.rows.map((row: any) => mapTurnRow(row));
  }

  async upsertItem(args: {
    id: string;
    threadId: string;
    turnId: string;
    type: string;
    payload: ThreadItem;
    createdAt?: number;
    updatedAt?: number;
  }) {
    const createdAt = args.createdAt ?? nowUnixSeconds();
    const updatedAt = args.updatedAt ?? createdAt;
    await this.pool.query(
      `INSERT INTO items (id, thread_id, turn_id, type, payload_json, created_at, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT(id) DO UPDATE SET
         type=EXCLUDED.type,
         payload_json=EXCLUDED.payload_json,
         updated_at=EXCLUDED.updated_at`,
      [args.id, args.threadId, args.turnId, args.type, JSON.stringify(args.payload), createdAt, updatedAt]
    );
    await this.updateThread({ id: args.threadId, updatedAt });
  }

  async listItemRecords(turnId: string): Promise<CodexItemRecord[]> {
    const result = await this.pool.query<any>(
      `SELECT id, thread_id, turn_id, type, payload_json, created_at, updated_at
       FROM items
       WHERE turn_id=$1
       ORDER BY created_at ASC, id ASC`,
      [turnId]
    );
    return result.rows.map((row: any) => mapItemRow(row));
  }

  async readThread(threadId: string, includeTurns: boolean): Promise<Thread | null> {
    const thread = await this.getThreadRecord(threadId);
    if (!thread) return null;
    if (!includeTurns) {
      return toThread(thread, []);
    }

    const turns = await this.listTurnRecords(threadId);
    const mappedTurns: Turn[] = [];

    for (const turn of turns) {
      const itemRows = await this.listItemRecords(turn.id);
      const items = itemRows
        .map((row) => safeJsonParse<ThreadItem>(row.payloadJson))
        .filter((item): item is ThreadItem => item != null);

      mappedTurns.push({
        id: turn.id,
        items,
        status: turn.status,
        error: turn.errorJson ? safeJsonParse<TurnError>(turn.errorJson) : null,
      });
    }

    return toThread(thread, mappedTurns);
  }

  async removeTurns(threadId: string, turnIds: string[]) {
    const normalizedTurnIds = Array.from(
      new Set(
        turnIds
          .map((turnId) => (typeof turnId === "string" ? turnId.trim() : ""))
          .filter((turnId) => turnId.length > 0)
      )
    );
    if (normalizedTurnIds.length === 0) return;

    const turnPlaceholders = normalizedTurnIds.map((_, idx) => `$${idx + 2}`).join(", ");
    const turnParams: unknown[] = [threadId, ...normalizedTurnIds];

    await this.pool.query(
      `DELETE FROM items
       WHERE thread_id=$1 AND turn_id IN (${turnPlaceholders})`,
      turnParams as any[]
    );

    await this.pool.query(
      `DELETE FROM turns
       WHERE thread_id=$1 AND id IN (${turnPlaceholders})`,
      turnParams as any[]
    );

    const eventRows = await this.pool.query<any>(
      `SELECT id, event_json
       FROM thread_events
       WHERE thread_id=$1
       ORDER BY created_at ASC, id ASC`,
      [threadId]
    );

    const turnSet = new Set(normalizedTurnIds);
    const eventIdsToDelete = eventRows.rows
      .filter((row) => {
        const turnId = extractTurnIdFromThreadEvent(row?.event_json);
        return turnId ? turnSet.has(turnId) : false;
      })
      .map((row) => Number(row.id))
      .filter((id) => Number.isFinite(id));

    if (eventIdsToDelete.length > 0) {
      const eventPlaceholders = eventIdsToDelete.map((_, idx) => `$${idx + 1}`).join(", ");
      await this.pool.query(`DELETE FROM thread_events WHERE id IN (${eventPlaceholders})`, eventIdsToDelete as any[]);
    }

    await this.updateThread({ id: threadId, updatedAt: nowUnixSeconds() });
    await this.rewriteThreadTranscript(threadId);
  }

  async appendThreadEvent(args: { threadId: string; projectId?: string | null; event: Record<string, unknown>; createdAt?: number }) {
    const createdAt = args.createdAt ?? nowUnixSeconds();
    const payload = JSON.stringify(args.event);

    await this.pool.query(
      `INSERT INTO thread_events (thread_id, event_json, created_at)
       VALUES ($1,$2,$3)`,
      [args.threadId, payload, createdAt]
    );

    const logPath = threadTranscriptPath({ stateDir: this.stateDir }, { threadId: args.threadId, projectId: args.projectId ?? undefined });
    await mkdir(path.dirname(logPath), { recursive: true });
    await appendFile(logPath, `${payload}\n`, "utf8");
  }

  async assignThreadToSession(args: { threadId: string; sessionId: string | null }) {
    await this.pool.query(`UPDATE threads SET session_id=$1 WHERE id=$2`, [args.sessionId, args.threadId]);
  }

  async findThreadBySession(sessionId: string): Promise<string | null> {
    const rows = await this.pool.query<any>(
      `SELECT id
       FROM threads
       WHERE session_id=$1
       ORDER BY updated_at DESC, id DESC
       LIMIT 1`,
      [sessionId]
    );
    if (rows.rows.length === 0) return null;
    return String(rows.rows[0].id ?? "");
  }

  async findSessionByThread(threadId: string): Promise<{ projectId: string; sessionId: string } | null> {
    const rows = await this.pool.query<any>(
      `SELECT s.project_id, s.id AS session_id
       FROM threads t
       JOIN sessions s ON s.id = t.session_id
       WHERE t.id=$1
       LIMIT 1`,
      [threadId]
    );
    if (rows.rows.length === 0) return null;
    const row = rows.rows[0];
    if (!row?.project_id || !row?.session_id) return null;
    return {
      projectId: String(row.project_id),
      sessionId: String(row.session_id),
    };
  }

  async removeThread(threadId: string) {
    const record = await this.getThreadRecord(threadId);
    await this.pool.query(`DELETE FROM threads WHERE id=$1`, [threadId]);
    const logPath = threadTranscriptPath({ stateDir: this.stateDir }, { threadId, projectId: record?.projectId ?? undefined });
    await rm(logPath, { force: true });
  }

  async removeSessionThreadMappings(sessionId: string) {
    const threadRows = await this.pool.query<any>(`SELECT id FROM threads WHERE session_id=$1`, [sessionId]);
    for (const row of threadRows.rows) {
      const threadId = String(row.id ?? "");
      if (!threadId) continue;
      await this.removeThread(threadId);
    }
  }

  async removeProjectStorage(projectId: string) {
    await rm(projectDir({ stateDir: this.stateDir }, projectId), { recursive: true, force: true });
  }

  async removeSessionTranscript(projectId: string, sessionId: string) {
    await rm(sessionTranscriptPath({ stateDir: this.stateDir }, projectId, sessionId), { force: true });
  }

  private async rewriteThreadTranscript(threadId: string) {
    const thread = await this.getThreadRecord(threadId);
    if (!thread) return;

    const rows = await this.pool.query<any>(
      `SELECT event_json
       FROM thread_events
       WHERE thread_id=$1
       ORDER BY created_at ASC, id ASC`,
      [threadId]
    );

    const logPath = threadTranscriptPath({ stateDir: this.stateDir }, { threadId, projectId: thread.projectId ?? undefined });
    await mkdir(path.dirname(logPath), { recursive: true });
    const content = rows.rows.map((row) => `${String(row.event_json ?? "{}")}\n`).join("");
    await writeFile(logPath, content, "utf8");
  }
}

function safeJsonParse<T>(raw: unknown): T | null {
  if (typeof raw !== "string") return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

function extractTurnIdFromThreadEvent(rawEvent: unknown): string | null {
  const event = safeJsonParse<Record<string, unknown>>(rawEvent);
  if (!event) return null;

  const params = event.params;
  if (!params || typeof params !== "object" || Array.isArray(params)) return null;
  const paramsRecord = params as Record<string, unknown>;

  const turnId = normalizeNonEmptyString(paramsRecord.turnId);
  if (turnId) return turnId;

  const turn = paramsRecord.turn;
  if (!turn || typeof turn !== "object" || Array.isArray(turn)) return null;
  return normalizeNonEmptyString((turn as Record<string, unknown>).id);
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function mapThreadRow(row: any): CodexThreadRecord {
  return {
    id: String(row.id),
    projectId: row.project_id == null ? null : String(row.project_id),
    cwd: String(row.cwd ?? ""),
    modelProvider: String(row.model_provider ?? "unknown"),
    modelId: row.model_id == null ? null : String(row.model_id),
    preview: String(row.preview ?? ""),
    createdAt: Number(row.created_at ?? 0),
    updatedAt: Number(row.updated_at ?? 0),
    archived: Number(row.archived ?? 0) === 1,
    statusJson: row.status_json == null ? null : String(row.status_json),
    engine: String(row.engine ?? "pi"),
  };
}

function mapTurnRow(row: any): CodexTurnRecord {
  return {
    id: String(row.id),
    threadId: String(row.thread_id),
    status: String(row.status) as TurnStatus,
    errorJson: row.error_json == null ? null : String(row.error_json),
    createdAt: Number(row.created_at ?? 0),
    completedAt: row.completed_at == null ? null : Number(row.completed_at),
  };
}

function mapItemRow(row: any): CodexItemRecord {
  return {
    id: String(row.id),
    threadId: String(row.thread_id),
    turnId: String(row.turn_id),
    type: String(row.type),
    payloadJson: String(row.payload_json),
    createdAt: Number(row.created_at ?? 0),
    updatedAt: Number(row.updated_at ?? 0),
  };
}

export function toThread(record: CodexThreadRecord, turns: Turn[]): Thread {
  return {
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
    turns,
  };
}
