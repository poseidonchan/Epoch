import test from "node:test";
import assert from "node:assert/strict";

import { handleTurnSteer } from "../dist/index.js";

test("handleTurnSteer validates params and forwards to codex-app-server engine", async () => {
  const calls = [];
  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_steer_1");
      return {
        id: threadId,
        projectId: "proj_1",
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
          calls.push(args);
          return {};
        },
      };
    },
  };

  const steerText = "Please focus on the second queued steer message.";
  const result = await handleTurnSteer(
    {
      repository,
      engines,
    },
    {
      threadId: "thr_steer_1",
      turnId: "turn_steer_1",
      text: steerText,
    }
  );

  assert.deepEqual(result, {});
  assert.deepEqual(calls, [
    {
      threadId: "thr_steer_1",
      turnId: "turn_steer_1",
      input: [
        {
          type: "text",
          text: steerText,
          text_elements: [],
        },
      ],
    },
  ]);
});
