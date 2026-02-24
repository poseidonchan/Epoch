import type { DbPool } from "../db/db.js";
import { previewFromText, type ThreadItem } from "./types.js";
import { CodexRepository } from "./repository.js";

export async function backfillLegacySessionsToCodex(opts: { pool: DbPool; stateDir: string }) {
  const repository = new CodexRepository({ pool: opts.pool, stateDir: opts.stateDir });

  const sessions = await opts.pool.query<any>(
    `SELECT id, project_id, title, created_at, updated_at
     FROM sessions
     ORDER BY created_at ASC`
  );

  for (const session of sessions.rows) {
    const threadId = `thr_${String(session.id).replace(/[^a-zA-Z0-9_-]/g, "_")}`;
    const existing = await repository.getThreadRecord(threadId);
    if (existing) continue;

    const messages = await opts.pool.query<any>(
      `SELECT id, role, content, ts
       FROM messages
       WHERE session_id=$1 AND project_id=$2
       ORDER BY ts ASC, id ASC`,
      [session.id, session.project_id]
    );

    const createdAt = toUnixSeconds(session.created_at);
    const updatedAt = toUnixSeconds(session.updated_at);

    await repository.createThread({
      id: threadId,
      projectId: String(session.project_id),
      cwd: `projects/${session.project_id}`,
      modelProvider: "openai-codex",
      modelId: null,
      preview: previewFromText(String(session.title ?? "")),
      statusJson: null,
      engine: "pi",
      createdAt,
    });
    await repository.updateThread({ id: threadId, updatedAt });

    let activeTurnId: string | null = null;
    let turnCreatedAt = createdAt;

    for (const message of messages.rows) {
      const role = String(message.role ?? "");
      const content = String(message.content ?? "");
      const messageTs = toUnixSeconds(message.ts);

      if (role === "user") {
        activeTurnId = `turn_${String(message.id).replace(/[^a-zA-Z0-9_-]/g, "_")}`;
        turnCreatedAt = messageTs;
        await repository.createTurn({
          id: activeTurnId,
          threadId,
          status: "inProgress",
          error: null,
          createdAt: messageTs,
        });

        const userItem: ThreadItem = {
          type: "userMessage",
          id: `item_${String(message.id).replace(/[^a-zA-Z0-9_-]/g, "_")}`,
          content: [
            {
              type: "text",
              text: content,
              text_elements: [],
            },
          ],
        };
        await repository.upsertItem({
          id: userItem.id,
          threadId,
          turnId: activeTurnId,
          type: userItem.type,
          payload: userItem,
          createdAt: messageTs,
          updatedAt: messageTs,
        });
        continue;
      }

      if (role === "assistant" && activeTurnId) {
        const assistantItem: ThreadItem = {
          type: "agentMessage",
          id: `item_${String(message.id).replace(/[^a-zA-Z0-9_-]/g, "_")}`,
          text: content,
        };
        await repository.upsertItem({
          id: assistantItem.id,
          threadId,
          turnId: activeTurnId,
          type: assistantItem.type,
          payload: assistantItem,
          createdAt: messageTs,
          updatedAt: messageTs,
        });

        await repository.updateTurn({
          id: activeTurnId,
          status: "completed",
          completedAt: messageTs,
          touchThreadId: threadId,
        });

        await repository.updateThread({
          id: threadId,
          preview: previewFromText(content),
          updatedAt: messageTs,
        });
        continue;
      }

      if (activeTurnId && messageTs >= turnCreatedAt) {
        await repository.updateTurn({
          id: activeTurnId,
          status: "completed",
          completedAt: messageTs,
          touchThreadId: threadId,
        });
      }
    }
  }
}

function toUnixSeconds(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.floor(value);
  }
  const parsed = Date.parse(String(value ?? ""));
  if (!Number.isFinite(parsed)) {
    return Math.floor(Date.now() / 1000);
  }
  return Math.floor(parsed / 1000);
}
