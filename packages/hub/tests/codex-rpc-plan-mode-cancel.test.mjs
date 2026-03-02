import test from "node:test";
import assert from "node:assert/strict";

import { CodexConnectionState, CodexRpcRouter } from "../dist/index.js";

test("turn/steer cancels pending implement-confirmation prompts for the same session", async () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(JSON.parse(payload));
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const pendingInputs = [
    {
      requestId: "req_impl_prompt",
      kind: "implement_confirmation",
    },
  ];
  const resolvedRequestIds = [];

  const repository = {
    async findSessionByThread(threadId) {
      assert.equal(threadId, "thr_cancel");
      return { projectId: "proj_cancel", sessionId: "session_cancel" };
    },
    async listPendingInputsForSession(args) {
      assert.equal(args.sessionId, "session_cancel");
      return [...pendingInputs];
    },
    async resolvePendingInput(args) {
      resolvedRequestIds.push(args.requestId);
      const index = pendingInputs.findIndex((entry) => entry.requestId === args.requestId);
      if (index >= 0) pendingInputs.splice(index, 1);
      return true;
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_cancel");
      return {
        id: threadId,
        projectId: "proj_cancel",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: null,
        engine: "codex-app-server",
      };
    },
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async steerTurn(args) {
          assert.equal(args.threadId, "thr_cancel");
          assert.equal(args.turnId, "turn_cancel");
          return { ok: true };
        },
      };
    },
  };

  const router = new CodexRpcRouter({
    repository,
    engines,
    connection: conn,
    token: "tok_cancel",
  });

  await router.handleRequest({
    id: "req_init",
    method: "initialize",
    params: {
      clientInfo: { name: "Epoch", version: "0.1.0" },
      capabilities: {},
    },
  });
  await router.handleNotification({ method: "initialized", params: {} });

  const pendingPromptPromise = conn.sendServerRequest(
    "item/tool/requestUserInput",
    {
      threadId: "thr_cancel",
      turnId: "turn_plan",
      itemId: "item_plan_prompt",
      questions: [],
    },
    undefined,
    "req_impl_prompt",
    {
      sessionId: "session_cancel",
      kind: "implement_confirmation",
    }
  );

  await router.handleRequest({
    id: "req_turn_steer",
    method: "turn/steer",
    params: {
      threadId: "thr_cancel",
      turnId: "turn_cancel",
      input: [
        {
          type: "text",
          text: "Continue with this direction",
          text_elements: [],
        },
      ],
    },
  });

  assert.deepEqual(resolvedRequestIds, ["req_impl_prompt"]);
  await assert.rejects(pendingPromptPromise, /superseded/i);
  assert.equal(conn.pendingUserInputSummaryMap().get("session_cancel"), undefined);

  const turnSteerResponse = sent.find((message) => message.id === "req_turn_steer");
  assert.ok(turnSteerResponse);
  assert.deepEqual(turnSteerResponse.result, { ok: true });
});
