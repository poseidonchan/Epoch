import test from "node:test";
import assert from "node:assert/strict";

import { handleThreadStart, handleTurnStart } from "../dist/index.js";

test("handleThreadStart rejects an explicit model that codex-app-server does not advertise", async () => {
  const repository = {
    stateDirectory() {
      return "/tmp/epoch-thread-model-validation";
    },
    async query(sql) {
      const normalized = String(sql);
      if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
        return [];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async createThread() {
      assert.fail("thread should not be created when explicit model validation fails");
    },
  };

  await assert.rejects(
    () =>
      handleThreadStart(
        {
          repository,
          engines: {
            defaultEngineName() {
              return "epoch-hpc";
            },
            async getEngine(name) {
              assert.equal(name, "codex-app-server");
              return {
                name: "codex-app-server",
                async modelList() {
                  return {
                    data: [
                      {
                        id: "gpt-5.3-codex",
                        provider: "openai-codex",
                        displayName: "GPT-5.3 Codex",
                        supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
                        isDefault: true,
                      },
                    ],
                  };
                },
              };
            },
          },
        },
        {
          projectId: "123e4567-e89b-12d3-a456-426614174240",
          model: "gpt-4.1",
        }
      ),
    /incompatible with current server model list/i
  );
});

test("handleThreadStart allows an explicit model that codex-app-server advertises", async () => {
  let createdThread = null;
  const repository = {
    stateDirectory() {
      return "/tmp/epoch-thread-model-validation-ok";
    },
    async query(sql) {
      const normalized = String(sql);
      if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
        return [];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async createThread(args) {
      createdThread = args;
    },
  };

  const result = await handleThreadStart(
    {
      repository,
      engines: {
        defaultEngineName() {
          return "epoch-hpc";
        },
        async getEngine(name) {
          assert.equal(name, "codex-app-server");
          return {
            name: "codex-app-server",
            async modelList() {
              return {
                data: [
                  {
                    id: "gpt-5.3-codex",
                    provider: "openai-codex",
                    displayName: "GPT-5.3 Codex",
                    supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
                    isDefault: true,
                  },
                ],
              };
            },
          };
        },
      },
    },
    {
      projectId: "123e4567-e89b-12d3-a456-426614174241",
      model: "gpt-5.3-codex",
    }
  );

  assert.equal(result.model, "gpt-5.3-codex");
  assert.equal(createdThread.modelId, "gpt-5.3-codex");
});

test("handleTurnStart rejects an explicit model that codex-app-server does not advertise", async () => {
  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_model_validation_1");
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
      assert.equal(threadId, "thr_model_validation_1");
      assert.equal(includeTurns, true);
      return {
        id: threadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/hpc/projects/proj_1",
        cliVersion: "epoch/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      };
    },
    async updateThread() {
      assert.fail("thread metadata should not be updated when explicit model validation fails");
    },
  };

  await assert.rejects(
    () =>
      handleTurnStart(
        {
          repository,
          engines: {
            defaultEngineName() {
              return "epoch-hpc";
            },
            async getEngine(name) {
              if (name === "codex-app-server") {
                return {
                  name: "codex-app-server",
                  async modelList() {
                    return {
                      data: [
                        {
                          id: "gpt-5.3-codex",
                          provider: "openai-codex",
                          displayName: "GPT-5.3 Codex",
                          supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
                          isDefault: true,
                        },
                      ],
                    };
                  },
                };
              }
              if (name === "epoch-hpc") {
                return {
                  name: "epoch-hpc",
                  async startTurn() {
                    assert.fail("turn should not start when explicit model validation fails");
                  },
                };
              }
              assert.fail(`Unexpected engine request: ${name}`);
            },
          },
        },
        {
          threadId: "thr_model_validation_1",
          model: "gpt-4.1",
          input: [{ type: "text", text: "hello", text_elements: [] }],
        }
      ),
    /incompatible with current server model list/i
  );
});
