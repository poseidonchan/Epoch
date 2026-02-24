import test from "node:test";
import assert from "node:assert/strict";

import { BoundedWorkQueue, CodexConnectionState, handleInitialize, updateThreadPreviewFromItems } from "../dist/index.js";

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
    clientInfo: { name: "LabOS", version: "0.1.0" },
    capabilities: {
      experimentalApi: true,
      optOutNotificationMethods: ["item/agentMessage/delta", "turn/diff/updated"],
    },
  });

  assert.equal(response.userAgent, "@labos/hub/0.1.0");
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

function deferred() {
  let resolve;
  const promise = new Promise((res) => {
    resolve = res;
  });
  return { promise, resolve };
}
