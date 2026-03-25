import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { handleEpochSessionCreate, handleEpochSessionUpdate } from "../dist/index.js";

test("handleEpochSessionCreate inherits type-shaped sandbox config from the project", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-session-sandbox-create-"));
  const projectId = "proj_session_sandbox_create";
  const sessionId = "sess_session_sandbox_create";
  const expectedSandbox = { type: "dangerFullAccess" };
  const createdThreads = [];

  const repository = {
    stateDirectory() {
      return stateDir;
    },
    async ensureProjectStorage() {},
    async createThread(args) {
      createdThreads.push(args);
    },
    async assignThreadToSession() {},
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT id, backend_engine") && normalized.includes("FROM projects")) {
        return [
          {
            id: projectId,
            backend_engine: "epoch-hpc",
            codex_model_provider: "openai",
            codex_model_id: "gpt-5.3-codex",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify(expectedSandbox),
            hpc_workspace_state: "ready",
          },
        ];
      }
      if (normalized.includes("SELECT COUNT(1) AS count")) {
        return [{ count: 0 }];
      }
      if (normalized.includes("SELECT hpc_workspace_path FROM projects")) {
        return [{ hpc_workspace_path: "/tmp/project-session-sandbox-create" }];
      }
      if (normalized.includes("INSERT INTO sessions")) {
        return [];
      }
      if (normalized.includes("UPDATE sessions SET codex_thread_id")) {
        return [];
      }
      if (normalized.includes("SELECT * FROM sessions WHERE id=$1")) {
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: "Session 1",
            lifecycle: "active",
            created_at: "2026-03-01T00:00:00.000Z",
            updated_at: "2026-03-01T00:00:00.000Z",
            backend_engine: "epoch-hpc",
            codex_thread_id: "thr_session_sandbox_create",
            codex_model: "gpt-5.3-codex",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify(expectedSandbox),
            hpc_workspace_state: "ready",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const result = await handleEpochSessionCreate(
    {
      repository,
      engines: {},
    },
    { projectId }
  );

  assert.deepEqual(result.session.codexSandbox, expectedSandbox);
  assert.deepEqual(JSON.parse(createdThreads[0].statusJson).sandbox, expectedSandbox);
});

test("handleEpochSessionCreate accepts type-shaped sandbox overrides", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-session-sandbox-create-override-"));
  const projectId = "proj_session_sandbox_override";
  const sessionId = "sess_session_sandbox_override";
  const expectedSandbox = {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: ["/tmp/project-session-sandbox-override"],
    excludeTmpdirEnvVar: false,
    excludeSlashTmp: true,
  };
  let insertedSessionArgs = null;

  const repository = {
    stateDirectory() {
      return stateDir;
    },
    async ensureProjectStorage() {},
    async createThread() {},
    async assignThreadToSession() {},
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT id, backend_engine") && normalized.includes("FROM projects")) {
        return [
          {
            id: projectId,
            backend_engine: "epoch-hpc",
            codex_model_provider: "openai",
            codex_model_id: "gpt-5.3-codex",
            codex_approval_policy: "on-request",
            codex_sandbox_json: null,
            hpc_workspace_state: "ready",
          },
        ];
      }
      if (normalized.includes("SELECT COUNT(1) AS count")) {
        return [{ count: 0 }];
      }
      if (normalized.includes("SELECT hpc_workspace_path FROM projects")) {
        return [{ hpc_workspace_path: "/tmp/project-session-sandbox-override" }];
      }
      if (normalized.includes("INSERT INTO sessions")) {
        insertedSessionArgs = args;
        return [];
      }
      if (normalized.includes("UPDATE sessions SET codex_thread_id")) {
        return [];
      }
      if (normalized.includes("SELECT * FROM sessions WHERE id=$1")) {
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: "Session 1",
            lifecycle: "active",
            created_at: "2026-03-01T00:00:00.000Z",
            updated_at: "2026-03-01T00:00:00.000Z",
            backend_engine: "epoch-hpc",
            codex_thread_id: "thr_session_sandbox_override",
            codex_model: "gpt-5.3-codex",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: insertedSessionArgs[10],
            hpc_workspace_state: "ready",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const result = await handleEpochSessionCreate(
    {
      repository,
      engines: {},
    },
    {
      projectId,
      codexSandbox: expectedSandbox,
    }
  );

  assert.deepEqual(JSON.parse(insertedSessionArgs[10]), expectedSandbox);
  assert.deepEqual(result.session.codexSandbox, expectedSandbox);
});

test("handleEpochSessionUpdate accepts type-shaped sandbox updates", async () => {
  const projectId = "proj_session_sandbox_update";
  const sessionId = "sess_session_sandbox_update";
  const threadId = "thr_session_sandbox_update";
  const expectedSandbox = {
    type: "workspaceWrite",
    networkAccess: true,
    writableRoots: ["/tmp/project-session-sandbox-update"],
    excludeTmpdirEnvVar: false,
    excludeSlashTmp: true,
  };
  let sessionRow = {
    id: sessionId,
    project_id: projectId,
    title: "Session 1",
    lifecycle: "active",
    created_at: "2026-03-01T00:00:00.000Z",
    updated_at: "2026-03-01T00:00:00.000Z",
    backend_engine: "epoch-hpc",
    codex_thread_id: threadId,
    codex_model: "gpt-5.3-codex",
    codex_model_provider: "openai",
    codex_approval_policy: "on-request",
    codex_sandbox_json: JSON.stringify({ mode: "workspace-write" }),
    hpc_workspace_state: "ready",
  };
  let capturedUpdateArgs = null;

  const repository = {
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("UPDATE sessions\n     SET")) {
        capturedUpdateArgs = args;
        sessionRow = {
          ...sessionRow,
          codex_sandbox_json: args[0],
          updated_at: args[1],
        };
        return [];
      }
      if (normalized.includes("SELECT * FROM sessions") && normalized.includes("WHERE project_id=$1 AND id=$2")) {
        return [sessionRow];
      }
      if (normalized.includes("UPDATE sessions SET codex_thread_id")) {
        return [];
      }
      if (normalized.includes("SELECT hpc_workspace_path FROM projects")) {
        return [{ hpc_workspace_path: "/tmp/project-session-sandbox-update" }];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id,
        engine: "epoch-hpc",
        cwd: "/tmp/project-session-sandbox-update",
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project-session-sandbox-update",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
          syncState: "ready",
        }),
      };
    },
    async updateThread() {},
    async readThread(id) {
      assert.equal(id, threadId);
      return {
        id,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/tmp/project-session-sandbox-update",
        cliVersion: "epoch/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      };
    },
    async assignThreadToSession() {},
  };

  const result = await handleEpochSessionUpdate(
    {
      repository,
      engines: {},
    },
    {
      projectId,
      sessionId,
      codexSandbox: expectedSandbox,
    }
  );

  assert.deepEqual(JSON.parse(capturedUpdateArgs[0]), expectedSandbox);
  assert.deepEqual(result.session.codexSandbox, expectedSandbox);
});
