import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import * as hub from "../dist/index.js";

test("CodexRepository upserts push devices and records live session snapshots", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-live-sync-repo-"));

  try {
    const pool = await hub.connectDb(path.join(stateDir, "epoch.sqlite"));
    try {
      await hub.runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
      const repo = new hub.CodexRepository({ pool, stateDir });

      await pool.query(
        `INSERT INTO projects (id, name, created_at, updated_at) VALUES ($1,$2,$3,$4)`,
        ["project_live_1", "Project Live", "2026-03-23T00:00:00.000Z", "2026-03-23T00:00:00.000Z"]
      );
      await pool.query(
        `INSERT INTO sessions (id, project_id, title, lifecycle, created_at, updated_at, backend_engine, codex_thread_id)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
        [
          "session_live_1",
          "project_live_1",
          "Session Live",
          "active",
          "2026-03-23T00:00:00.000Z",
          "2026-03-23T00:00:00.000Z",
          "codex-app-server",
          "thread_live_1",
        ]
      );

      await repo.createThread({
        id: "thread_live_1",
        projectId: "project_live_1",
        cwd: "/tmp/workspace",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        statusJson: null,
        engine: "codex-app-server",
      });
      await repo.assignThreadToSession({ threadId: "thread_live_1", sessionId: "session_live_1" });
      await repo.createTurn({
        id: "thread_live_1::turn_live_1",
        threadId: "thread_live_1",
        status: "completed",
        error: null,
        createdAt: 1_763_000_000,
      });
      await repo.upsertPendingInput({
        token: "tok_live_1",
        requestId: "pending_prompt_1",
        sessionId: "session_live_1",
        threadId: "thread_live_1",
        method: "item/tool/requestUserInput",
        kind: "prompt",
        params: { prompt: "Need input" },
        createdAt: 1_763_000_001,
      });

      await repo.upsertPushDevice({
        serverId: "server_live_1",
        installationId: "install_live_1",
        apnsToken: "apns_live_1",
        environment: "sandbox",
        deviceName: "Epoch iPhone",
        platform: "iOS",
        seenAt: "2026-03-23T00:00:00.000Z",
      });
      await repo.upsertPushDevice({
        serverId: "server_live_1",
        installationId: "install_live_1",
        apnsToken: "apns_live_2",
        environment: "sandbox",
        deviceName: "Epoch iPhone 2",
        platform: "iOS",
        seenAt: "2026-03-23T00:01:00.000Z",
      });

      const registeredDevices = await repo.listPushDevices({ serverId: "server_live_1" });
      assert.equal(registeredDevices.length, 1);
      assert.equal(registeredDevices[0].apnsToken, "apns_live_2");
      assert.equal(registeredDevices[0].deviceName, "Epoch iPhone 2");

      await repo.appendLiveSessionChange({
        token: "tok_live_1",
        serverId: "server_live_1",
        projectId: "project_live_1",
        sessionId: "session_live_1",
        threadId: "thread_live_1",
        reason: "turn/completed",
        metadata: {
          turnId: "turn_live_1",
          turnStatus: "completed",
        },
        createdAt: 1_763_000_002,
      });

      const changes = await repo.listLiveSessionChanges({
        token: "tok_live_1",
        cursor: 0,
        limit: 50,
      });

      assert.equal(changes.nextCursor, 1);
      assert.equal(changes.changedSessions.length, 1);
      assert.deepEqual(changes.changedSessions[0], {
        serverId: "server_live_1",
        projectId: "project_live_1",
        sessionId: "session_live_1",
        threadId: "thread_live_1",
        turnStatus: "completed",
        statusText: "completed",
        pendingApprovals: 0,
        pendingPrompts: 1,
        lastAssistantItemPreview: "",
        lastEventAt: 1_763_000_002,
      });
    } finally {
      await pool.end();
    }
  } finally {
    await rm(stateDir, { recursive: true, force: true });
  }
});
