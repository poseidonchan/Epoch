import test from "node:test";
import assert from "node:assert/strict";

import { CodexConnectionState, CodexRpcRouter, handleLabosSessionRead } from "../dist/index.js";

test("thread/tokenUsage/updated parses nested tokenUsage payload and preserves modelId when missing", async () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(JSON.parse(payload));
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const queries = [];
  const repository = {
    async getThreadRecord() {
      return null;
    },
    async findSessionByThread(threadId) {
      assert.equal(threadId, "thr_usage_nested");
      return { projectId: "proj_usage_nested", sessionId: "session_usage_nested" };
    },
    async appendThreadEvent() {},
    async query(sql, args = []) {
      queries.push({ sql: String(sql), args });
      return [];
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines: {},
    connection: conn,
    token: "tok_usage_nested",
  });

  await router.persistAndSendNotification("thread/tokenUsage/updated", {
    threadId: "thr_usage_nested",
    tokenUsage: {
      modelContextWindow: 200000,
      last: {
        inputTokens: 4321,
        totalTokens: 6789,
      },
    },
  });

  assert.equal(queries.length, 1);
  assert.match(queries[0].sql, /context_model_id=COALESCE\(\$1, context_model_id\)/);
  assert.equal(queries[0].args[0], null);
  assert.equal(queries[0].args[1], 200000);
  assert.equal(queries[0].args[2], 4321);
  assert.equal(queries[0].args[3], 6789);
  assert.equal(typeof queries[0].args[4], "string");
  assert.equal(queries[0].args[5], "proj_usage_nested");
  assert.equal(queries[0].args[6], "session_usage_nested");

  const forwarded = sent.find((message) => message.method === "thread/tokenUsage/updated");
  assert.ok(forwarded);
});

test("thread/tokenUsage/updated remains backward compatible with legacy flat payload", async () => {
  const conn = new CodexConnectionState(
    {
      send() {},
    },
    { maxIngressQueueDepth: 8 }
  );

  const queries = [];
  const repository = {
    async getThreadRecord() {
      return null;
    },
    async findSessionByThread(threadId) {
      assert.equal(threadId, "thr_usage_legacy");
      return { projectId: "proj_usage_legacy", sessionId: "session_usage_legacy" };
    },
    async appendThreadEvent() {},
    async query(sql, args = []) {
      queries.push({ sql: String(sql), args });
      return [];
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines: {},
    connection: conn,
    token: "tok_usage_legacy",
  });

  await router.persistAndSendNotification("thread/tokenUsage/updated", {
    threadId: "thr_usage_legacy",
    tokenUsage: {
      contextWindow: 128000,
      inputTokens: 2222,
      totalTokens: 3333,
      model: "gpt-5.1",
    },
  });

  assert.equal(queries.length, 1);
  assert.equal(queries[0].args[0], "gpt-5.1");
  assert.equal(queries[0].args[1], 128000);
  assert.equal(queries[0].args[2], 2222);
  assert.equal(queries[0].args[3], 3333);
  assert.equal(queries[0].args[5], "proj_usage_legacy");
  assert.equal(queries[0].args[6], "session_usage_legacy");
});

test("handleLabosSessionRead includes context payload with remaining tokens", async () => {
  const projectId = "123e4567-e89b-12d3-a456-426614174200";
  const sessionId = "123e4567-e89b-12d3-a456-426614174201";
  const threadId = "123e4567-e89b-12d3-a456-426614174202";

  const repository = {
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("FROM sessions") && normalized.includes("WHERE project_id=$1 AND id=$2")) {
        assert.equal(args[0], projectId);
        assert.equal(args[1], sessionId);
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: "Session Read Context",
            lifecycle: "active",
            created_at: "2026-02-01T00:00:00.000Z",
            updated_at: "2026-02-02T00:00:00.000Z",
            backend_engine: "codex-app-server",
            codex_thread_id: threadId,
            codex_model: "gpt-5.1",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify({ mode: "workspace-write" }),
            hpc_workspace_state: "queued",
            permission_level: "full",
            context_model_id: "gpt-5.1",
            context_window_tokens: 100000,
            context_used_input_tokens: 12000,
            context_used_tokens: 19000,
            context_updated_at: "2026-02-26T10:00:00.000Z",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
      return {
        id: threadId,
        projectId,
        cwd: "projects/123e4567-e89b-12d3-a456-426614174200",
        modelProvider: "openai",
        modelId: "gpt-5.1",
        preview: "",
        createdAt: 1,
        updatedAt: 2,
        archived: false,
        statusJson: JSON.stringify({ syncState: "ready" }),
        engine: "codex-app-server",
      };
    },
    async updateThread() {},
    async readThread(id, includeTurns) {
      assert.equal(id, threadId);
      assert.equal(typeof includeTurns, "boolean");
      return {
        id: threadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 2,
        path: null,
        cwd: "projects/123e4567-e89b-12d3-a456-426614174200",
        cliVersion: "@labos/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      };
    },
    async assignThreadToSession(args) {
      assert.equal(args.threadId, threadId);
      assert.equal(args.sessionId, sessionId);
    },
    async listPendingInputsForSession() {
      return [];
    },
    async readPlanSnapshotForSession() {
      return null;
    },
  };

  const result = await handleLabosSessionRead(
    {
      repository,
      engines: {},
      pendingUserInputSummaryBySession: new Map(),
      runtimeToken: "tok_read_context",
    },
    {
      projectId,
      sessionId,
      includeTurns: false,
    }
  );

  assert.equal(result.context.projectId, projectId);
  assert.equal(result.context.sessionId, sessionId);
  assert.equal(result.context.permissionLevel, "full");
  assert.equal(result.context.modelId, "gpt-5.1");
  assert.equal(result.context.contextWindowTokens, 100000);
  assert.equal(result.context.usedInputTokens, 12000);
  assert.equal(result.context.usedTokens, 19000);
  assert.equal(result.context.remainingTokens, 88000);
  assert.equal(result.context.updatedAt, "2026-02-26T10:00:00.000Z");
});
