import test from "node:test";
import assert from "node:assert/strict";

import { CodexRpcRouter } from "../dist/index.js";

test("requestPlanImplementationConfirmation resolves session thread before starting follow-up turn", async () => {
  const currentThreadId = "123e4567-e89b-12d3-a456-426614174240";
  const staleThreadId = "123e4567-e89b-12d3-a456-426614174241";
  const started = [];
  const upsertedPending = [];
  const resolvedPending = [];

  const repository = {
    async listPendingInputsForSession(args) {
      assert.equal(args.sessionId, "session_followup");
      return [];
    },
    async findThreadBySession(sessionId) {
      assert.equal(sessionId, "session_followup");
      return currentThreadId;
    },
    async readThread(threadId) {
      assert.equal(threadId, currentThreadId);
      return {
        id: threadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/tmp/project",
        cliVersion: "@epoch/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [
          {
            id: "turn_plan",
            status: "completed",
            error: null,
            items: [
              {
                type: "agentMessage",
                id: "item_plan",
                text: "<proposed_plan>\n1. Do work\n</proposed_plan>",
              },
            ],
          },
        ],
      };
    },
    async upsertPendingInput(args) {
      upsertedPending.push(args);
    },
    async resolvePendingInput(args) {
      resolvedPending.push(args);
      return true;
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, currentThreadId);
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async updateThread() {},
    async clearPlanSnapshotForSession() {},
    async query() {
      return [];
    },
    async updateTurn() {},
    async createTurn() {},
    async upsertItem() {},
    async appendThreadEvent() {},
    async findSessionByThread() {
      return { projectId: "proj_followup", sessionId: "session_followup" };
    },
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          started.push(args);
          return {
            turn: {
              id: "turn_followup",
              items: [],
              status: "inProgress",
              error: null,
            },
            events: emptyEvents(),
          };
        },
      };
    },
  };

  const notifications = [];
  const connection = {
    async sendServerRequest(method, params) {
      assert.equal(method, "item/tool/requestUserInput");
      assert.equal(params.threadId, currentThreadId);
      return {
        answers: {
          epoch_plan_implementation_decision: {
            answers: ["Yes, implement this plan"],
          },
        },
      };
    },
    sendNotification(method, params) {
      notifications.push({ method, params });
    },
    shouldSendNotification() {
      return true;
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines,
    connection,
    token: "tok_followup",
  });

  await router.requestPlanImplementationConfirmation({
    threadId: staleThreadId,
    turnId: "turn_plan",
    sessionId: "session_followup",
  });

  assert.equal(upsertedPending.length, 1);
  assert.equal(upsertedPending[0].threadId, currentThreadId);
  assert.equal(started.length, 1);
  assert.equal(started[0].threadId, currentThreadId);
  assert.equal(started[0].input[0].text, "Implement it");
  assert.equal(started[0].collaborationMode.mode, "default");
  assert.equal(resolvedPending.length, 1);
  assert.equal(notifications.length, 0);
});

test("requestPlanImplementationConfirmation keeps pending unresolved when follow-up start fails", async () => {
  const currentThreadId = "123e4567-e89b-12d3-a456-426614174242";
  const staleThreadId = "123e4567-e89b-12d3-a456-426614174243";
  const resolvedPending = [];

  const repository = {
    async listPendingInputsForSession() {
      return [];
    },
    async findThreadBySession() {
      return currentThreadId;
    },
    async readThread() {
      return {
        id: currentThreadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/tmp/project",
        cliVersion: "@epoch/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [
          {
            id: "turn_plan",
            status: "completed",
            error: null,
            items: [
              {
                type: "agentMessage",
                id: "item_plan",
                text: "<proposed_plan>\n1. Do work\n</proposed_plan>",
              },
            ],
          },
        ],
      };
    },
    async upsertPendingInput() {},
    async resolvePendingInput(args) {
      resolvedPending.push(args);
      return true;
    },
    async getThreadRecord() {
      return {
        id: currentThreadId,
        projectId: null,
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "codex-app-server",
      };
    },
    async updateThread() {},
    async clearPlanSnapshotForSession() {},
    async query() {
      return [];
    },
    async updateTurn() {},
    async createTurn() {},
    async upsertItem() {},
    async appendThreadEvent() {},
    async findSessionByThread() {
      return { projectId: "proj_followup_fail", sessionId: "session_followup_fail" };
    },
  };

  const engines = {
    async getEngine() {
      return {
        async startTurn() {
          throw new Error("follow-up turn failed");
        },
      };
    },
  };

  const connection = {
    async sendServerRequest() {
      return {
        answers: {
          epoch_plan_implementation_decision: {
            answers: ["Yes, implement this plan"],
          },
        },
      };
    },
    sendNotification() {},
    shouldSendNotification() {
      return true;
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines,
    connection,
    token: "tok_followup_fail",
  });

  await assert.rejects(
      () =>
        router.requestPlanImplementationConfirmation({
        threadId: staleThreadId,
        turnId: "turn_plan",
        sessionId: "session_followup_fail",
      }),
    /follow-up turn failed/
  );
  assert.equal(resolvedPending.length, 0);
});

test("notifyPlanImplementationFailure emits codex error notification", async () => {
  const sent = [];
  const router = new CodexRpcRouter({
    repository: {},
    engines: {},
    connection: {
      sendNotification(method, params) {
        sent.push({ method, params });
      },
      shouldSendNotification() {
        return true;
      },
    },
    token: "tok_notify_followup",
  });

  router.notifyPlanImplementationFailure({
    sessionId: "session_notify",
    threadId: "thread_notify",
    turnId: "turn_notify",
    error: new Error("network timeout"),
  });

  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, "codex/event/error");
  assert.equal(sent[0].params.sessionId, "session_notify");
  assert.equal(sent[0].params.threadId, "thread_notify");
  assert.match(sent[0].params.error.message, /Plan implementation failed: network timeout/);
});

function emptyEvents() {
  return (async function* stream() {})();
}
