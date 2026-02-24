import test from "node:test";
import assert from "node:assert/strict";

import { handleTurnStart } from "../dist/index.js";

test("handleTurnStart forwards plan mode as collaborationMode=plan", async () => {
  const threadId = "123e4567-e89b-12d3-a456-426614174111";
  const thread = {
    id: threadId,
    preview: "",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 1,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@labos/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  let capturedStartArgs = null;

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(id) {
      assert.equal(id, threadId);
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
    async readThread(id) {
      assert.equal(id, threadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
    async createTurn() {},
    async upsertItem() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
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

  await handleTurnStart(
    {
      repository,
      engines,
    },
    {
      threadId,
      input: [{ type: "text", text: "plan this change" }],
      planMode: true,
    }
  );

  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.collaborationMode.mode, "plan");
  assert.equal(capturedStartArgs.collaborationMode.settings.model, "gpt-5.3-codex");
});

test("handleTurnStart injects indexed project snippets into turn input", async () => {
  const originalApiKey = process.env.OPENAI_API_KEY;
  delete process.env.OPENAI_API_KEY;

  try {
    const threadId = "123e4567-e89b-12d3-a456-426614174113";
    const thread = {
      id: threadId,
      preview: "",
      modelProvider: "openai",
      createdAt: 1,
      updatedAt: 1,
      path: null,
      cwd: "/tmp/project",
      cliVersion: "@labos/hub/0.1.0",
      source: "appServer",
      gitInfo: null,
      turns: [],
    };

    let capturedStartArgs = null;

    const dbPool = {
      async query(sql) {
        const normalized = String(sql);
        if (normalized.includes("FROM artifacts a")) {
          return {
            rows: [
              {
                path: "uploads/experiment-notes.txt",
                modified_at: "2026-02-24T00:00:00.000Z",
                size_bytes: 120,
                index_status: "indexed",
                index_summary: "Contains marker RED-PLANT-8842.",
                indexed_at: "2026-02-24T00:00:05.000Z",
              },
            ],
          };
        }
        if (normalized.includes("FROM project_file_chunk")) {
          return {
            rows: [
              {
                artifact_path: "uploads/experiment-notes.txt",
                chunk_index: 0,
                content: "Retrieval marker RED-PLANT-8842. The launch code is 8842.",
                embedding_json: null,
              },
            ],
          };
        }
        return { rows: [] };
      },
    };

    const repository = {
      dbPool() {
        return dbPool;
      },
      async query() {
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId: "proj_ctx_1",
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
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread() {},
      async createTurn() {},
      async upsertItem() {},
    };

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
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

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "What is the launch code in the uploaded experiment notes?" }],
      }
    );

    assert.ok(capturedStartArgs);
    const firstText = capturedStartArgs.input.find((part) => part.type === "text")?.text ?? "";
    assert.ok(firstText.includes("[LABOS_PROJECT_CONTEXT]"));
    assert.ok(firstText.includes("uploads/experiment-notes.txt#0"));
    assert.ok(firstText.includes("RED-PLANT-8842"));
    assert.ok(firstText.includes("User request:"));
  } finally {
    if (originalApiKey == null) {
      delete process.env.OPENAI_API_KEY;
    } else {
      process.env.OPENAI_API_KEY = originalApiKey;
    }
  }
});

test("handleTurnStart still forwards collaborationMode when stored model is missing", async () => {
  const originalModel = process.env.LABOS_MODEL;
  const originalPrimary = process.env.LABOS_MODEL_PRIMARY;
  process.env.LABOS_MODEL = "openai-codex/gpt-5.3-codex";
  process.env.LABOS_MODEL_PRIMARY = "openai-codex/gpt-5.3-codex";

  try {
    const threadId = "123e4567-e89b-12d3-a456-426614174112";
    const thread = {
      id: threadId,
      preview: "",
      modelProvider: "openai",
      createdAt: 1,
      updatedAt: 1,
      path: null,
      cwd: "/tmp/project",
      cliVersion: "@labos/hub/0.1.0",
      source: "appServer",
      gitInfo: null,
      turns: [],
    };

    let capturedStartArgs = null;

    const repository = {
      async query() {
        return [];
      },
      async getThreadRecord(id) {
        assert.equal(id, threadId);
        return {
          id: threadId,
          projectId: "proj_1",
          cwd: "/tmp/project",
          modelProvider: "openai",
          modelId: null,
          preview: "",
          createdAt: 1,
          updatedAt: 1,
          archived: false,
          statusJson: JSON.stringify({
            modelProvider: "openai",
            model: null,
            cwd: "/tmp/project",
            approvalPolicy: "on-request",
            sandbox: { mode: "workspace-write" },
            reasoningEffort: null,
          }),
          engine: "codex-app-server",
        };
      },
      async readThread(id) {
        assert.equal(id, threadId);
        return JSON.parse(JSON.stringify(thread));
      },
      async updateThread() {},
      async createTurn() {},
      async upsertItem() {},
    };

    const engines = {
      async getEngine(name) {
        assert.equal(name, "codex-app-server");
        return {
          async startTurn(args) {
            capturedStartArgs = args;
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

    await handleTurnStart(
      {
        repository,
        engines,
      },
      {
        threadId,
        input: [{ type: "text", text: "plan this change" }],
        planMode: true,
      }
    );

    assert.ok(capturedStartArgs);
    assert.equal(capturedStartArgs.model, "gpt-5.3-codex");
    assert.equal(capturedStartArgs.collaborationMode.mode, "plan");
    assert.equal(capturedStartArgs.collaborationMode.settings.model, "gpt-5.3-codex");
  } finally {
    if (originalModel == null) {
      delete process.env.LABOS_MODEL;
    } else {
      process.env.LABOS_MODEL = originalModel;
    }
    if (originalPrimary == null) {
      delete process.env.LABOS_MODEL_PRIMARY;
    } else {
      process.env.LABOS_MODEL_PRIMARY = originalPrimary;
    }
  }
});

test("handleTurnStart normalizes legacy pi threads and starts with codex engine", async () => {
  const legacyThreadId = "123e4567-e89b-12d3-a456-426614174099";
  const priorTurn = {
    id: "turn_prev",
    status: "completed",
    error: null,
    items: [
      {
        type: "userMessage",
        id: "item_user_prev",
        content: [{ type: "text", text: "previous question", text_elements: [] }],
      },
      {
        type: "agentMessage",
        id: "item_agent_prev",
        text: "previous answer",
      },
    ],
  };

  const thread = {
    id: legacyThreadId,
    preview: "previous question",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 2,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@labos/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [priorTurn],
  };

  let capturedStartArgs = null;

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, legacyThreadId);
      return {
        id: legacyThreadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "previous question",
        createdAt: 1,
        updatedAt: 2,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/tmp/project",
          approvalPolicy: "on-request",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
        }),
        engine: "pi",
      };
    },
    async readThread(threadId) {
      assert.equal(threadId, legacyThreadId);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread(args) {
      assert.equal(args.id, legacyThreadId);
      assert.equal(args.engine, "codex-app-server");
    },
    async createTurn() {},
    async upsertItem() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async startTurn(args) {
          capturedStartArgs = args;
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
      threadId: legacyThreadId,
      input: [{ type: "text", text: "new question" }],
    }
  );

  assert.equal(prepared.threadId, legacyThreadId);
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.threadId, legacyThreadId);
  assert.equal(capturedStartArgs.input.length, 1);
  assert.equal(capturedStartArgs.historyTurns.length, 1);
  assert.equal(capturedStartArgs.historyTurns[0].id, "turn_prev");
});

test("handleTurnStart seeds history via thread/resume when repairing codex thread ids", async () => {
  const localThread = {
    id: "thr_local",
    preview: "old preview",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@labos/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_local_1",
        status: "completed",
        error: null,
        items: [
          {
            type: "userMessage",
            id: "item_user_1",
            content: [{ type: "text", text: "hello from pi", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_agent_1",
            text: "hello from agent",
          },
        ],
      },
    ],
  };

  const repairedThread = {
    id: "123e4567-e89b-12d3-a456-426614174000",
    preview: "repaired",
    modelProvider: "openai",
    createdAt: 20,
    updatedAt: 20,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@openai/codex/1.0.0",
    source: "appServer",
    gitInfo: null,
    turns: [],
  };

  const threadRecords = new Map([
    [
      "thr_local",
      {
        id: "thr_local",
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "old preview",
        createdAt: 10,
        updatedAt: 11,
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
      },
    ],
  ]);

  const threadSnapshots = new Map([["thr_local", JSON.parse(JSON.stringify(localThread))]]);

  let capturedResumeParams = null;
  let capturedStartArgs = null;

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      return threadRecords.get(threadId) ?? null;
    },
    async readThread(threadId) {
      const snapshot = threadSnapshots.get(threadId);
      return snapshot ? JSON.parse(JSON.stringify(snapshot)) : null;
    },
    async createThread(args) {
      threadRecords.set(args.id, {
        id: args.id,
        projectId: args.projectId ?? null,
        cwd: args.cwd,
        modelProvider: args.modelProvider,
        modelId: args.modelId ?? null,
        preview: args.preview ?? "",
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        archived: false,
        statusJson: args.statusJson ?? null,
        engine: args.engine ?? "codex-app-server",
      });
      threadSnapshots.set(args.id, {
        id: args.id,
        preview: args.preview ?? "",
        modelProvider: args.modelProvider,
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        path: null,
        cwd: args.cwd,
        cliVersion: "@labos/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      });
    },
    async updateThread(args) {
      const existing = threadRecords.get(args.id);
      if (!existing) return;
      threadRecords.set(args.id, {
        ...existing,
        cwd: args.cwd ?? existing.cwd,
        modelProvider: args.modelProvider ?? existing.modelProvider,
        modelId: Object.prototype.hasOwnProperty.call(args, "modelId") ? (args.modelId ?? null) : existing.modelId,
        preview: args.preview ?? existing.preview,
        statusJson: Object.prototype.hasOwnProperty.call(args, "statusJson") ? args.statusJson : existing.statusJson,
        engine: args.engine ?? existing.engine,
        updatedAt: args.updatedAt ?? existing.updatedAt,
      });
    },
    async findSessionByThread() {
      return null;
    },
    async assignThreadToSession() {},
    async createTurn() {},
    async updateTurn() {},
    async upsertItem() {},
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadStart() {
          return { thread: repairedThread };
        },
        async threadResume(params) {
          capturedResumeParams = params;
          const resumed = {
            ...repairedThread,
            turns: JSON.parse(JSON.stringify(localThread.turns)),
          };
          threadSnapshots.set(repairedThread.id, resumed);
          return { thread: resumed };
        },
        async startTurn(args) {
          capturedStartArgs = args;
          return {
            turn: {
              id: "turn_new",
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
      threadId: "thr_local",
      input: [{ type: "text", text: "continue" }],
    }
  );

  assert.equal(prepared.threadId, repairedThread.id);
  assert.ok(capturedResumeParams);
  assert.equal(capturedResumeParams.threadId, repairedThread.id);
  assert.equal(Array.isArray(capturedResumeParams.history), true);
  assert.equal(capturedResumeParams.history.length >= 2, true);
  assert.equal(capturedResumeParams.history[0].role, "user");
  assert.equal(capturedResumeParams.history[1].role, "assistant");
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.threadId, repairedThread.id);
  assert.equal(Array.isArray(capturedStartArgs.historyTurns), true);
});

test("handleTurnStart repairs codex thread when turn/start reports missing thread", async () => {
  const originalThreadId = "123e4567-e89b-12d3-a456-426614174111";
  const repairedThreadId = "123e4567-e89b-12d3-a456-426614174222";

  const localThread = {
    id: originalThreadId,
    preview: "hello",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/project",
    cliVersion: "@labos/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_local_1",
        status: "completed",
        error: null,
        items: [
          {
            type: "userMessage",
            id: "item_user_1",
            content: [{ type: "text", text: "hello", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_agent_1",
            text: "world",
          },
        ],
      },
    ],
  };

  const threadRecords = new Map([
    [
      originalThreadId,
      {
        id: originalThreadId,
        projectId: "proj_1",
        cwd: "/tmp/project",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "hello",
        createdAt: 10,
        updatedAt: 11,
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
      },
    ],
  ]);

  const threadSnapshots = new Map([[originalThreadId, JSON.parse(JSON.stringify(localThread))]]);
  const startTurnThreadIds = [];
  let resumeCallCount = 0;

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      return threadRecords.get(threadId) ?? null;
    },
    async readThread(threadId) {
      const snapshot = threadSnapshots.get(threadId);
      return snapshot ? JSON.parse(JSON.stringify(snapshot)) : null;
    },
    async createThread(args) {
      threadRecords.set(args.id, {
        id: args.id,
        projectId: args.projectId ?? null,
        cwd: args.cwd,
        modelProvider: args.modelProvider,
        modelId: args.modelId ?? null,
        preview: args.preview ?? "",
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        archived: false,
        statusJson: args.statusJson ?? null,
        engine: args.engine ?? "codex-app-server",
      });
      threadSnapshots.set(args.id, {
        id: args.id,
        preview: args.preview ?? "",
        modelProvider: args.modelProvider,
        createdAt: args.createdAt ?? 0,
        updatedAt: args.createdAt ?? 0,
        path: null,
        cwd: args.cwd,
        cliVersion: "@labos/hub/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      });
    },
    async updateThread(args) {
      const existing = threadRecords.get(args.id);
      if (!existing) return;
      threadRecords.set(args.id, {
        ...existing,
        cwd: args.cwd ?? existing.cwd,
        modelProvider: args.modelProvider ?? existing.modelProvider,
        modelId: Object.prototype.hasOwnProperty.call(args, "modelId") ? (args.modelId ?? null) : existing.modelId,
        preview: args.preview ?? existing.preview,
        statusJson: Object.prototype.hasOwnProperty.call(args, "statusJson") ? args.statusJson : existing.statusJson,
        engine: args.engine ?? existing.engine,
        updatedAt: args.updatedAt ?? existing.updatedAt,
      });
    },
    async findSessionByThread() {
      return null;
    },
    async assignThreadToSession() {},
    async createTurn() {},
    async updateTurn() {},
    async upsertItem() {},
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadStart() {
          return {
            thread: {
              id: repairedThreadId,
              preview: "repaired",
              modelProvider: "openai",
              createdAt: 20,
              updatedAt: 20,
              path: null,
              cwd: "/tmp/project",
              cliVersion: "@openai/codex/1.0.0",
              source: "appServer",
              gitInfo: null,
              turns: [],
            },
          };
        },
        async threadResume(params) {
          resumeCallCount += 1;
          assert.equal(params.threadId, repairedThreadId);
          threadSnapshots.set(repairedThreadId, {
            id: repairedThreadId,
            preview: "repaired",
            modelProvider: "openai",
            createdAt: 20,
            updatedAt: 20,
            path: null,
            cwd: "/tmp/project",
            cliVersion: "@openai/codex/1.0.0",
            source: "appServer",
            gitInfo: null,
            turns: JSON.parse(JSON.stringify(localThread.turns)),
          });
          return {
            thread: threadSnapshots.get(repairedThreadId),
          };
        },
        async startTurn(args) {
          startTurnThreadIds.push(args.threadId);
          if (args.threadId === originalThreadId) {
            throw new Error("thread not found");
          }
          return {
            turn: {
              id: "turn_new",
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
      threadId: originalThreadId,
      input: [{ type: "text", text: "continue" }],
    }
  );

  assert.equal(prepared.threadId, repairedThreadId);
  assert.equal(startTurnThreadIds.length, 2);
  assert.deepEqual(startTurnThreadIds, [originalThreadId, repairedThreadId]);
  assert.equal(resumeCallCount >= 1, true);
});

async function* emptyEvents() {}
