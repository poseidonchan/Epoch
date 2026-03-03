import test from "node:test";
import assert from "node:assert/strict";

import { BoundedWorkQueue, CodexConnectionState, CodexEngineRegistry, handleInitialize, normalizeEngineName, updateThreadPreviewFromItems } from "../dist/index.js";

test("handleInitialize stores capabilities and supports optOutNotificationMethods extension", () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(payload);
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const response = handleInitialize(conn, {
    clientInfo: { name: "Epoch", version: "0.1.0" },
    capabilities: {
      experimentalApi: true,
      optOutNotificationMethods: ["item/agentMessage/delta", "turn/diff/updated"],
    },
  });

  assert.equal(response.userAgent, "@epoch/hub/0.1.0");
  assert.equal(conn.initializedRequestReceived, true);
  assert.equal(conn.capabilities.experimentalApi, true);
  assert.equal(conn.capabilities.optOutNotificationMethods.has("item/agentMessage/delta"), true);
  assert.equal(conn.capabilities.optOutNotificationMethods.has("turn/diff/updated"), true);

  conn.sendNotification("item/agentMessage/delta", { delta: "skip" });
  conn.sendNotification("turn/started", { threadId: "thr_1" });

  assert.equal(sent.length, 1);
  assert.match(sent[0], /turn\/started/);
});

test("BoundedWorkQueue rejects enqueue when depth exceeds limit", async () => {
  const queue = new BoundedWorkQueue(1);
  const started = [];
  const gate = deferred();

  const acceptedFirst = queue.enqueue(async () => {
    started.push("first");
    await gate.promise;
  });
  const acceptedSecond = queue.enqueue(async () => {
    started.push("second");
  });
  const acceptedThird = queue.enqueue(async () => {
    started.push("third");
  });

  assert.equal(acceptedFirst, true);
  assert.equal(acceptedSecond, true);
  assert.equal(acceptedThird, false);

  gate.resolve();
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(started, ["first", "second"]);
});

test("updateThreadPreviewFromItems prefers latest user text and falls back to assistant text", () => {
  const preview = updateThreadPreviewFromItems([
    {
      id: "turn_1",
      status: "completed",
      error: null,
      items: [
        {
          type: "agentMessage",
          id: "item_a",
          text: "Initial assistant reply",
        },
      ],
    },
    {
      id: "turn_2",
      status: "completed",
      error: null,
      items: [
        {
          type: "userMessage",
          id: "item_u",
          content: [
            {
              type: "text",
              text: "Most recent user question",
              text_elements: [],
            },
          ],
        },
      ],
    },
  ]);

  assert.equal(preview, "Most recent user question");
});

test("engine normalization and defaults include epoch-hpc", async () => {
  assert.equal(normalizeEngineName("hpc"), "epoch-hpc");
  assert.equal(normalizeEngineName("epoch-hpc"), "epoch-hpc");
  assert.equal(normalizeEngineName("codex"), "codex-app-server");
  assert.equal(normalizeEngineName("codex-app-server"), "codex-app-server");
  assert.equal(normalizeEngineName("pi"), "codex-app-server");
  assert.equal(normalizeEngineName("pi-adapter"), "codex-app-server");

  const registry = new CodexEngineRegistry({
    config: null,
    stateDir: "/tmp",
  });
  assert.equal(registry.defaultEngineName(), "epoch-hpc");
  await registry.close();
});

test("CodexConnectionState replays unresolved server requests to replacement websocket and tracks pending by session", async () => {
  const ws1Sent = [];
  const ws2Sent = [];

  const ws1 = {
    send(payload) {
      ws1Sent.push(JSON.parse(payload));
    },
    close() {},
  };
  const ws2 = {
    send(payload) {
      ws2Sent.push(JSON.parse(payload));
    },
    close() {},
  };

  const conn = new CodexConnectionState(ws1, { maxIngressQueueDepth: 8 });
  const pendingPromise = conn.sendServerRequest(
    "item/tool/requestUserInput",
    {
      threadId: "thr_replay_1",
      turnId: "turn_replay_1",
      itemId: "item_prompt_1",
      questions: [],
    },
    undefined,
    "req_replay_1",
    {
      sessionId: "session_replay_1",
      kind: "prompt",
    }
  );

  assert.equal(ws1Sent.length, 1);
  assert.equal(ws1Sent[0].id, "req_replay_1");
  assert.equal(conn.pendingUserInputSummaryMap().get("session_replay_1")?.count, 1);

  conn.attachWebSocket(ws2);

  assert.equal(ws2Sent.length, 1);
  assert.equal(ws2Sent[0].id, "req_replay_1");
  assert.equal(ws2Sent[0].method, "item/tool/requestUserInput");

  const handled = conn.handleClientResponse({
    id: "req_replay_1",
    result: {
      answers: {},
    },
  });
  assert.equal(handled, true);
  await pendingPromise;

  assert.equal(conn.pendingUserInputSummaryMap().get("session_replay_1"), undefined);
});

test("CodexConnectionState cancels pending requests by session and kind", async () => {
  const wsSent = [];
  const ws = {
    send(payload) {
      wsSent.push(JSON.parse(payload));
    },
    close() {},
  };

  const conn = new CodexConnectionState(ws, { maxIngressQueueDepth: 8 });
  const cancelledPromise = conn.sendServerRequest(
    "item/tool/requestUserInput",
    {
      threadId: "thr_cancel_1",
      turnId: "turn_cancel_1",
      itemId: "item_cancel_1",
      questions: [],
    },
    undefined,
    "req_cancel_1",
    {
      sessionId: "session_cancel_1",
      kind: "implement_confirmation",
    }
  );
  const keepPromptPromise = conn.sendServerRequest(
    "item/tool/requestUserInput",
    {
      threadId: "thr_keep_1",
      turnId: "turn_keep_1",
      itemId: "item_keep_1",
      questions: [],
    },
    undefined,
    "req_keep_1",
    {
      sessionId: "session_cancel_1",
      kind: "prompt",
    }
  );
  const keepSessionPromise = conn.sendServerRequest(
    "item/tool/requestUserInput",
    {
      threadId: "thr_keep_2",
      turnId: "turn_keep_2",
      itemId: "item_keep_2",
      questions: [],
    },
    undefined,
    "req_keep_2",
    {
      sessionId: "session_cancel_2",
      kind: "implement_confirmation",
    }
  );

  assert.equal(wsSent.length, 3);
  const cancelled = conn.cancelPendingServerRequests({
    sessionId: "session_cancel_1",
    kind: "implement_confirmation",
    reason: "superseded",
  });
  assert.deepEqual(cancelled, ["req_cancel_1"]);
  await assert.rejects(cancelledPromise, /superseded/);

  const summary = conn.pendingUserInputSummaryMap();
  assert.equal(summary.get("session_cancel_1")?.count, 1);
  assert.equal(summary.get("session_cancel_1")?.kind, "prompt");
  assert.equal(summary.get("session_cancel_2")?.count, 1);
  assert.equal(summary.get("session_cancel_2")?.kind, "implement_confirmation");

  conn.handleClientResponse({ id: "req_keep_1", result: { answers: {} } });
  conn.handleClientResponse({ id: "req_keep_2", result: { answers: {} } });
  await keepPromptPromise;
  await keepSessionPromise;
  assert.equal(conn.pendingUserInputSummaryMap().size, 0);
});

function deferred() {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return { promise, resolve };
}
