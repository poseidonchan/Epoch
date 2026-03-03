import test from "node:test";
import assert from "node:assert/strict";

import { handleTurnStart } from "../dist/index.js";

test("handleTurnStart respects epoch-hpc thread.engine and skips codex repair", async () => {
  const engineCalls = [];
  const startCalls = [];
  const updateCalls = [];

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_engine_1");
      return {
        id: threadId,
        projectId: null,
        cwd: "/hpc/projects/proj_1",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/hpc/projects/proj_1",
          approvalPolicy: "never",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
          syncState: "ready",
        }),
        engine: "epoch-hpc",
      };
    },
    async readThread(threadId, includeTurns) {
      assert.equal(threadId, "thr_engine_1");
      assert.equal(includeTurns, true);
      return {
        id: threadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/hpc/projects/proj_1",
        cliVersion: "@epoch/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      };
    },
    async updateThread(args) {
      updateCalls.push(args);
    },
  };

  const engines = {
    defaultEngineName() {
      return "epoch-hpc";
    },
    async getEngine(name) {
      engineCalls.push(name);
      assert.equal(name, "epoch-hpc");
      return {
        name: "epoch-hpc",
        async startTurn(args) {
          startCalls.push(args);
          return {
            turn: {
              id: args.turnId,
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

  const prepared = await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId: "thr_engine_1",
      input: [
        {
          type: "text",
          text: "hello",
          text_elements: [],
        },
      ],
    }
  );

  assert.equal(prepared.threadId, "thr_engine_1");
  assert.equal(engineCalls.length, 1);
  assert.equal(startCalls.length, 1);
  assert.equal(startCalls[0].threadId, "thr_engine_1");
  assert.equal(updateCalls.length, 0);
});

function emptyEvents() {
  return (async function* stream() {})();
}

