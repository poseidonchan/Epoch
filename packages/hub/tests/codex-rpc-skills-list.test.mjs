import test from "node:test";
import assert from "node:assert/strict";

import { CodexConnectionState, CodexRpcRouter } from "../dist/index.js";

test("skills/list routes to engine and returns proxied payload", async () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(JSON.parse(payload));
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const calls = [];
  const payload = {
    data: [
      {
        cwd: "/tmp/workspace",
        skills: [],
        errors: [],
      },
    ],
  };
  const engines = {
    async getEngine(name) {
      assert.equal(name, null);
      return {
        name: "codex-app-server",
        async skillsList(params) {
          calls.push(params);
          return payload;
        },
      };
    },
  };

  const router = new CodexRpcRouter({
    repository: {},
    engines,
    connection: conn,
    token: "tok_skills_list",
  });
  await initializeRouter(router);

  await router.handleRequest({
    id: "req_skills_list",
    method: "skills/list",
    params: {
      cwds: ["/tmp/workspace"],
      forceReload: true,
    },
  });

  assert.deepEqual(calls, [{ cwds: ["/tmp/workspace"], forceReload: true }]);
  const response = sent.find((message) => message.id === "req_skills_list");
  assert.ok(response);
  assert.deepEqual(response.result, payload);
});

test("skills/list returns an error when engine does not support the method", async () => {
  const sent = [];
  const conn = new CodexConnectionState(
    {
      send(payload) {
        sent.push(JSON.parse(payload));
      },
    },
    { maxIngressQueueDepth: 8 }
  );

  const engines = {
    async getEngine() {
      return {
        name: "codex-app-server",
      };
    },
  };

  const router = new CodexRpcRouter({
    repository: {},
    engines,
    connection: conn,
    token: "tok_skills_unsupported",
  });
  await initializeRouter(router);

  await router.handleRequest({
    id: "req_skills_unsupported",
    method: "skills/list",
    params: {},
  });

  const response = sent.find((message) => message.id === "req_skills_unsupported");
  assert.ok(response);
  assert.equal(response.error.code, -32000);
  assert.match(response.error.message, /does not support skills\/list/i);
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
