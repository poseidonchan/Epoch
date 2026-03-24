import test from "node:test";
import assert from "node:assert/strict";

import { assertExplicitModelSupportedByCodexAppServer, loadOperatorVisibleModels } from "../dist/index.js";

test("loadOperatorVisibleModels uses codex-app-server model/list and prefers the engine default", async () => {
  const calls = [];
  const result = await loadOperatorVisibleModels({
    config: {
      serverId: "srv_1",
      token: "tok_1",
      createdAt: "2026-03-24T00:00:00.000Z",
      ai: {
        provider: "openai-codex",
        defaultModelId: "gpt-5.3-codex",
        auth: { type: "none" },
      },
    },
    engines: {
      async getEngine(name) {
        calls.push(name);
        return {
          name: "codex-app-server",
          async modelList() {
            return {
              data: [
                {
                  id: "codex-mini-2025-01-24",
                  provider: "openai-codex",
                  displayName: "Codex Mini",
                  supportedReasoningEfforts: [{ reasoningEffort: "medium" }],
                },
                {
                  id: "gpt-5.3-codex",
                  provider: "openai-codex",
                  displayName: "GPT-5.3 Codex",
                  supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "high" }],
                  isDefault: true,
                },
              ],
            };
          },
        };
      },
    },
  });

  assert.deepEqual(calls, ["codex-app-server"]);
  assert.equal(result.ok, true);
  assert.equal(result.provider, "openai-codex");
  assert.equal(result.defaultModelId, "gpt-5.3-codex");
  assert.deepEqual(
    result.models.map((entry) => entry.id),
    ["codex-mini-2025-01-24", "gpt-5.3-codex"]
  );
  assert.ok(!result.models.some((entry) => entry.id === "gpt-4.1"));
});

test("loadOperatorVisibleModels returns MODELS_UNAVAILABLE when codex-app-server fails", async () => {
  const result = await loadOperatorVisibleModels({
    config: null,
    engines: {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        throw new Error("spawn failed");
      },
    },
  });

  assert.equal(result.ok, false);
  assert.equal(result.code, "MODELS_UNAVAILABLE");
  assert.match(result.message, /model list/i);
  assert.equal(result.data?.source, "codex-app-server");
});

test("loadOperatorVisibleModels returns MODELS_UNAVAILABLE when codex-app-server returns no models", async () => {
  const result = await loadOperatorVisibleModels({
    config: null,
    engines: {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          name: "codex-app-server",
          async modelList() {
            return { data: [] };
          },
        };
      },
    },
  });

  assert.equal(result.ok, false);
  assert.equal(result.code, "MODELS_UNAVAILABLE");
});

test("assertExplicitModelSupportedByCodexAppServer rejects models outside the codex-app-server list", async () => {
  await assert.rejects(
    () =>
      assertExplicitModelSupportedByCodexAppServer({
        model: "gpt-4.1",
        engines: {
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
      }),
    /incompatible with current server model list/i
  );
});

test("assertExplicitModelSupportedByCodexAppServer allows models present in the codex-app-server list", async () => {
  await assert.doesNotReject(() =>
    assertExplicitModelSupportedByCodexAppServer({
      model: "gpt-5.3-codex",
      engines: {
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
    })
  );
});
