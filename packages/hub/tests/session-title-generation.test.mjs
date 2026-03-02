import test from "node:test";
import assert from "node:assert/strict";

import { handleEpochSessionGenerateTitle } from "../dist/index.js";
 
test("handleEpochSessionGenerateTitle falls back without API key", async () => {
  const projectId = "proj_title_fallback";
  const sessionId = "sess_title_fallback";
  const now = "2026-03-01T12:00:00.000Z";

  const updates = [];
  const repository = {
    stateDirectory() {
      return "/tmp/epoch-title-fallback-test";
    },
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT role, content FROM messages")) {
        return [{ role: "user", content: "Please build session auto title generation." }];
      }
      if (normalized.includes("UPDATE sessions SET title=$1, updated_at=$2")) {
        updates.push({ title: args[0], updatedAt: args[1], projectId: args[2], sessionId: args[3] });
        return [];
      }
      if (normalized.includes("FROM sessions") && normalized.includes("WHERE project_id=$1 AND id=$2")) {
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: updates[0]?.title ?? "Session 1",
            lifecycle: "active",
            created_at: now,
            updated_at: now,
            backend_engine: "codex-app-server",
            codex_thread_id: "thread_title_fallback",
            codex_model: "gpt-5.3-codex",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: "{}",
            hpc_workspace_state: "queued",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async readThread() {
      return null;
    },
  };

  const previousKey = process.env.OPENAI_API_KEY;
  delete process.env.OPENAI_API_KEY;
  try {
    const result = await handleEpochSessionGenerateTitle(
      {
        repository,
        engines: {},
      },
      {
        projectId,
        sessionId,
      }
    );

    assert.equal(updates.length, 1);
    assert.equal(typeof updates[0].title, "string");
    assert.ok(updates[0].title.length > 0);
    assert.equal(typeof result.session?.title, "string");
    assert.ok(result.session.title.length > 0);
  } finally {
    if (previousKey == null) {
      delete process.env.OPENAI_API_KEY;
    } else {
      process.env.OPENAI_API_KEY = previousKey;
    }
  }
});

test("handleEpochSessionGenerateTitle sanitizes model output before persisting", async (t) => {
  const projectId = "proj_title_sanitize";
  const sessionId = "sess_title_sanitize";
  const now = "2026-03-01T12:00:00.000Z";

  const updates = [];
  const repository = {
    stateDirectory() {
      return "/tmp/epoch-title-sanitize-test";
    },
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT role, content FROM messages")) {
        return [
          { role: "user", content: "Need title cleanup." },
          { role: "assistant", content: "Sure." },
        ];
      }
      if (normalized.includes("UPDATE sessions SET title=$1, updated_at=$2")) {
        updates.push({ title: args[0], updatedAt: args[1], projectId: args[2], sessionId: args[3] });
        return [];
      }
      if (normalized.includes("FROM sessions") && normalized.includes("WHERE project_id=$1 AND id=$2")) {
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: updates[0]?.title ?? "Session 1",
            lifecycle: "active",
            created_at: now,
            updated_at: now,
            backend_engine: "codex-app-server",
            codex_thread_id: "thread_title_sanitize",
            codex_model: "gpt-5.3-codex",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: "{}",
            hpc_workspace_state: "queued",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async readThread() {
      return null;
    },
  };

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        choices: [
          {
            message: {
              content: "Title: \"  Session Auto Rename Flow  \"\n",
            },
          },
        ],
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  const previousKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "sk-test";
  try {
    await handleEpochSessionGenerateTitle(
      {
        repository,
        engines: {},
      },
      {
        projectId,
        sessionId,
      }
    );
  } finally {
    if (previousKey == null) {
      delete process.env.OPENAI_API_KEY;
    } else {
      process.env.OPENAI_API_KEY = previousKey;
    }
  }

  assert.equal(updates.length, 1);
  assert.equal(updates[0].title, "Session Auto Rename Flow");
});

test("handleEpochSessionGenerateTitle prefers thread turns when messages table is empty", async () => {
  const projectId = "proj_title_turns";
  const sessionId = "sess_title_turns";
  const now = "2026-03-01T12:00:00.000Z";

  const updates = [];
  const repository = {
    stateDirectory() {
      return "/tmp/epoch-title-test";
    },
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT role, content FROM messages")) {
        return [];
      }
      if (normalized.includes("UPDATE sessions SET title=$1, updated_at=$2")) {
        updates.push({ title: args[0], updatedAt: args[1], projectId: args[2], sessionId: args[3] });
        return [];
      }
      if (normalized.includes("FROM sessions") && normalized.includes("WHERE project_id=$1 AND id=$2")) {
        return [
          {
            id: sessionId,
            project_id: projectId,
            title: updates[0]?.title ?? "Session 1",
            lifecycle: "active",
            created_at: now,
            updated_at: now,
            backend_engine: "codex-app-server",
            codex_thread_id: "thread_title_turns",
            codex_model: "gpt-5.3-codex",
            codex_model_provider: "openai",
            codex_approval_policy: "on-request",
            codex_sandbox_json: "{}",
            hpc_workspace_state: "queued",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async readThread(threadId, includeTurns) {
      assert.equal(threadId, "thread_title_turns");
      assert.equal(includeTurns, true);
      return {
        id: "thread_title_turns",
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 2,
        path: null,
        cwd: "/tmp",
        cliVersion: "@epoch/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [
          {
            id: "turn_1",
            status: "completed",
            error: null,
            items: [
              {
                type: "userMessage",
                id: "item_user_1",
                content: [
                  {
                    type: "text",
                    text: "Build an automatic session rename feature after first turn",
                    text_elements: [],
                  },
                ],
              },
              {
                type: "agentMessage",
                id: "item_agent_1",
                text: "We can generate a concise title from the first exchange.",
              },
            ],
          },
        ],
      };
    },
  };

  const result = await handleEpochSessionGenerateTitle(
    {
      repository,
      engines: {},
    },
    {
      projectId,
      sessionId,
    }
  );

  assert.equal(updates.length, 1);
  assert.equal(updates[0].projectId, projectId);
  assert.equal(updates[0].sessionId, sessionId);
  assert.equal(typeof updates[0].title, "string");
  assert.ok(updates[0].title.length > 0);
  assert.equal(typeof result.session?.title, "string");
  assert.ok(result.session.title.length > 0);
});
