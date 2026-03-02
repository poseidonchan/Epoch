import test from "node:test";
import assert from "node:assert/strict";

import { handleThreadRead, handleThreadRollback } from "../dist/index.js";

test("handleThreadRollback drops tail turns for pi threads and updates preview", async () => {
  const thread = {
    id: "thr_1",
    preview: "latest prompt",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 3,
    path: null,
    cwd: "/tmp",
    cliVersion: "@epoch/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_1",
        items: [
          {
            type: "userMessage",
            id: "item_u_1",
            content: [{ type: "text", text: "first prompt", text_elements: [] }],
          },
          { type: "agentMessage", id: "item_a_1", text: "first reply" },
        ],
        status: "completed",
        error: null,
      },
      {
        id: "turn_2",
        items: [
          {
            type: "userMessage",
            id: "item_u_2",
            content: [{ type: "text", text: "second prompt", text_elements: [] }],
          },
          { type: "agentMessage", id: "item_a_2", text: "second reply" },
        ],
        status: "completed",
        error: null,
      },
      {
        id: "turn_3",
        items: [
          {
            type: "userMessage",
            id: "item_u_3",
            content: [{ type: "text", text: "third prompt", text_elements: [] }],
          },
          { type: "agentMessage", id: "item_a_3", text: "third reply" },
        ],
        status: "completed",
        error: null,
      },
    ],
  };

  const removed = [];
  let updatedPreview = null;

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_1");
      return {
        id: "thr_1",
        projectId: null,
        cwd: "/tmp",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "latest prompt",
        createdAt: 1,
        updatedAt: 3,
        archived: false,
        statusJson: null,
        engine: "pi",
      };
    },
    async listTurnRecords(threadId) {
      assert.equal(threadId, "thr_1");
      return thread.turns.map((turn) => ({ id: turn.id }));
    },
    async removeTurns(threadId, turnIds) {
      assert.equal(threadId, "thr_1");
      removed.push(...turnIds);
      thread.turns = thread.turns.filter((turn) => !turnIds.includes(turn.id));
    },
    async readThread(threadId) {
      assert.equal(threadId, "thr_1");
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread(args) {
      if (Object.prototype.hasOwnProperty.call(args, "preview")) {
        updatedPreview = args.preview;
      }
    },
  };

  const engines = {
    async getEngine() {
      throw new Error("should not call engine for pi rollback");
    },
  };

  const result = await handleThreadRollback(
    {
      repository,
      engines,
    },
    { threadId: "thr_1", numTurns: 2 }
  );

  assert.deepEqual(removed, ["turn_2", "turn_3"]);
  assert.equal(updatedPreview, "first reply");
  assert.equal(result.thread.turns.length, 1);
  assert.equal(result.thread.turns[0].id, "turn_1");
});

test("handleThreadRollback falls back to local rollback when codex engine rollback fails", async () => {
  const thread = {
    id: "thr_codex_rollback_1",
    preview: "latest prompt",
    modelProvider: "openai",
    createdAt: 1,
    updatedAt: 3,
    path: null,
    cwd: "/tmp",
    cliVersion: "@epoch/hub/0.1.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_1",
        items: [
          {
            type: "userMessage",
            id: "item_u_1",
            content: [{ type: "text", text: "first prompt", text_elements: [] }],
          },
          { type: "agentMessage", id: "item_a_1", text: "first reply" },
        ],
        status: "completed",
        error: null,
      },
      {
        id: "turn_2",
        items: [
          {
            type: "userMessage",
            id: "item_u_2",
            content: [{ type: "text", text: "second prompt", text_elements: [] }],
          },
          { type: "agentMessage", id: "item_a_2", text: "second reply" },
        ],
        status: "completed",
        error: null,
      },
    ],
  };

  const removed = [];

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, thread.id);
      return {
        id: thread.id,
        projectId: null,
        cwd: "/tmp",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "latest prompt",
        createdAt: 1,
        updatedAt: 3,
        archived: false,
        statusJson: null,
        engine: "codex-app-server",
      };
    },
    async removeTurns(threadId, turnIds) {
      assert.equal(threadId, thread.id);
      removed.push(...turnIds);
      thread.turns = thread.turns.filter((turn) => !turnIds.includes(turn.id));
    },
    async readThread(threadId) {
      assert.equal(threadId, thread.id);
      return JSON.parse(JSON.stringify(thread));
    },
    async updateThread() {},
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadRollback() {
          throw new Error("thread not found");
        },
      };
    },
  };

  const result = await handleThreadRollback(
    {
      repository,
      engines,
    },
    { threadId: thread.id, numTurns: 1 }
  );

  assert.deepEqual(removed, ["turn_2"]);
  assert.equal(result.thread.turns.length, 1);
  assert.equal(result.thread.turns[0].id, "turn_1");
});

test("handleThreadRead proxies codex-app-server threads to engine and returns child turns", async () => {
  const proxiedThread = {
    id: "thr_codex_1",
    preview: "from child",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/proj",
    cliVersion: "@openai/codex/0.0.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "turn_1",
        items: [
          {
            type: "userMessage",
            id: "item_u_1",
            content: [{ type: "text", text: "hello", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "item_a_1",
            text: "world",
          },
        ],
        status: "completed",
        error: null,
      },
    ],
  };

  let persisted = false;
  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_codex_1");
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/proj",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 10,
        updatedAt: 10,
        archived: false,
        statusJson: null,
        engine: "codex-app-server",
      };
    },
    async createThread() {
      persisted = true;
    },
    async updateThread() {
      persisted = true;
    },
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
    async createTurn() {
      persisted = true;
    },
    async updateTurn() {
      persisted = true;
    },
    async upsertItem() {
      persisted = true;
    },
    async readThread() {
      throw new Error("readThread should not run for codex-app-server thread/read");
    },
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadRead(params) {
          assert.equal(params.threadId, "thr_codex_1");
          assert.equal(params.includeTurns, true);
          return { thread: proxiedThread };
        },
      };
    },
  };

  const result = await handleThreadRead(
    {
      repository,
      engines,
    },
    {
      threadId: "thr_codex_1",
      includeTurns: true,
    }
  );

  assert.equal(result.thread.id, "thr_codex_1");
  assert.equal(result.thread.turns.length, 1);
  assert.equal(result.thread.turns[0].id, "turn_1");
  assert.equal(persisted, true);
});

test("handleThreadRead persists codex-app-server turn/item IDs scoped by thread", async () => {
  const seenTurnIds = new Set();
  const seenItemIds = new Set();

  const makeThread = (threadId) => ({
    id: threadId,
    preview: "from child",
    modelProvider: "openai",
    createdAt: 10,
    updatedAt: 11,
    path: null,
    cwd: "/tmp/proj",
    cliVersion: "@openai/codex/0.0.0",
    source: "appServer",
    gitInfo: null,
    turns: [
      {
        id: "1",
        items: [
          {
            type: "userMessage",
            id: "1",
            content: [{ type: "text", text: "hello", text_elements: [] }],
          },
          {
            type: "agentMessage",
            id: "2",
            text: "world",
          },
        ],
        status: "completed",
        error: null,
      },
    ],
  });

  const repository = {
    async query() {
      return [];
    },
    async getThreadRecord(threadId) {
      return {
        id: threadId,
        projectId: null,
        cwd: "/tmp/proj",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 10,
        updatedAt: 10,
        archived: false,
        statusJson: null,
        engine: "codex-app-server",
      };
    },
    async createThread() {},
    async updateThread() {},
    async listTurnRecords() {
      return [];
    },
    async removeTurns() {},
    async createTurn(args) {
      if (seenTurnIds.has(args.id)) {
        throw new Error(`duplicate turn id ${args.id}`);
      }
      seenTurnIds.add(args.id);
    },
    async updateTurn() {},
    async upsertItem(args) {
      if (seenItemIds.has(args.id)) {
        throw new Error(`duplicate item id ${args.id}`);
      }
      seenItemIds.add(args.id);
    },
    async readThread() {
      throw new Error("readThread should not run for codex-app-server thread/read");
    },
  };

  const engines = {
    async getEngine(name) {
      assert.equal(name, "codex-app-server");
      return {
        async threadRead(params) {
          return { thread: makeThread(params.threadId) };
        },
      };
    },
  };

  await handleThreadRead(
    { repository, engines },
    { threadId: "thr_a", includeTurns: true }
  );
  await handleThreadRead(
    { repository, engines },
    { threadId: "thr_b", includeTurns: true }
  );

  assert.deepEqual(
    [...seenTurnIds].sort(),
    ["thr_a::turn::1", "thr_b::turn::1"]
  );
  assert.deepEqual(
    [...seenItemIds].sort(),
    ["thr_a::item::1", "thr_a::item::2", "thr_b::item::1", "thr_b::item::2"]
  );
});
