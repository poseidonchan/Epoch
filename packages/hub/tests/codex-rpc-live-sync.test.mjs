import test from "node:test";
import assert from "node:assert/strict";

import { CodexConnectionState, CodexRpcRouter } from "../dist/index.js";

test("epoch/live/changes returns repository-backed live session snapshots", async () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(JSON.parse(payload));
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const repository = {
    async listLiveSessionChanges(args) {
      assert.deepEqual(args, {
        token: "tok_live_changes",
        cursor: 41,
        limit: 25,
        sessionIds: ["session_live_1", "session_live_2"],
      });
      return {
        nextCursor: 44,
        changedSessions: [
          {
            serverId: "server_live_1",
            projectId: "project_live_1",
            sessionId: "session_live_1",
            threadId: "thread_live_1",
            turnStatus: "completed",
            statusText: "completed",
            pendingApprovals: 0,
            pendingPrompts: 1,
            lastAssistantItemPreview: "Plan is ready",
            lastEventAt: 1_763_000_000,
          },
        ],
      };
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines: {},
    connection: conn,
    token: "tok_live_changes",
    serverId: "server_live_1",
  });
  await initializeRouter(router);

  await router.handleRequest({
    id: "req_live_changes",
    method: "epoch/live/changes",
    params: {
      cursor: 41,
      limit: 25,
      sessionIds: ["session_live_1", "session_live_2"],
    },
  });

  const response = sent.find((message) => message.id === "req_live_changes");
  assert.ok(response);
  assert.deepEqual(response.result, {
    nextCursor: 44,
    changedSessions: [
      {
        serverId: "server_live_1",
        projectId: "project_live_1",
        sessionId: "session_live_1",
        threadId: "thread_live_1",
        turnStatus: "completed",
        statusText: "completed",
        pendingApprovals: 0,
        pendingPrompts: 1,
        lastAssistantItemPreview: "Plan is ready",
        lastEventAt: 1_763_000_000,
      },
    ],
  });
});

test("persistAndSendNotification records live-session changes for mapped codex sessions", async () => {
  const conn = new CodexConnectionState(
    {
      send() {},
    },
    { maxIngressQueueDepth: 8 }
  );

  const appended = [];
  const repository = {
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thread_live_1");
      return {
        id: threadId,
        projectId: "project_live_1",
      };
    },
    async findSessionByThread(threadId) {
      assert.equal(threadId, "thread_live_1");
      return {
        projectId: "project_live_1",
        sessionId: "session_live_1",
      };
    },
    async appendThreadEvent() {},
    async appendLiveSessionChange(args) {
      appended.push(args);
    },
    async query() {
      return [];
    },
    async updateTurn() {},
    async clearPlanSnapshotForSession() {},
  };

  const router = new CodexRpcRouter({
    repository,
    engines: {},
    connection: conn,
    token: "tok_live_changes",
    serverId: "server_live_1",
  });

  await router.persistAndSendNotification("turn/completed", {
    threadId: "thread_live_1",
    turn: {
      id: "turn_live_1",
      status: "completed",
      items: [],
      error: null,
    },
  });

  assert.equal(appended.length, 1);
  assert.deepEqual(appended[0], {
    token: "tok_live_changes",
    serverId: "server_live_1",
    projectId: "project_live_1",
    sessionId: "session_live_1",
    threadId: "thread_live_1",
    reason: "turn/completed",
    metadata: {
      turnId: "turn_live_1",
      turnStatus: "completed",
    },
    createdAt: appended[0].createdAt,
  });
  assert.equal(typeof appended[0].createdAt, "number");
});

async function initializeRouter(router) {
  await router.handleRequest({
    id: "req_init",
    method: "initialize",
    params: {
      clientInfo: { name: "Epoch", version: "0.1.0" },
      capabilities: {},
    },
  });
  await router.handleNotification({ method: "initialized", params: {} });
}
