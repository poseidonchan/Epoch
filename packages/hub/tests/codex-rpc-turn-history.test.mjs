import test from "node:test";
import assert from "node:assert/strict";

import { handleTurnStart } from "../dist/index.js";

test("handleTurnStart passes prior turns into engine startTurn for pi threads", async () => {
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
    id: "thr_pi_1",
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
      assert.equal(threadId, "thr_pi_1");
      return {
        id: "thr_pi_1",
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
      assert.equal(threadId, "thr_pi_1");
      return JSON.parse(JSON.stringify(thread));
    },
    async createTurn() {},
    async upsertItem() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "pi");
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
      threadId: "thr_pi_1",
      input: [{ type: "text", text: "new question" }],
    }
  );

  assert.equal(prepared.threadId, "thr_pi_1");
  assert.ok(capturedStartArgs);
  assert.equal(capturedStartArgs.threadId, "thr_pi_1");
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
