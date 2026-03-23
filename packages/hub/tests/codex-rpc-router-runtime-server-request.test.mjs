import test from "node:test";
import assert from "node:assert/strict";

import { CodexConnectionState, CodexRpcRouter } from "../dist/index.js";

test("router handles internal runtime/commandExecution/exec serverRequest via runtimeBridge", async () => {
  const sent = [];
  const ws = {
    send(payload) {
      sent.push(JSON.parse(payload));
    },
    close() {},
  };
  const conn = new CodexConnectionState(ws, { maxIngressQueueDepth: 8 });

  const turnFinished = deferred();

  const repository = {
    async query(sql) {
      const normalized = String(sql);
      if (normalized.includes("FROM turns") && normalized.includes("WHERE thread_id=$1")) {
        return [];
      }
      if (normalized.includes("FROM projects") && normalized.includes("codex_sandbox_json")) {
        return [{ codex_sandbox_json: null }];
      }
      if (normalized.includes("FROM sessions") && normalized.includes("codex_sandbox_json")) {
        return [{ codex_sandbox_json: JSON.stringify({ mode: "workspace-write", networkAccess: true }) }];
      }
      return [];
    },
    async listPendingInputsForSession() {
      return [];
    },
    async resolvePendingInput() {
      return true;
    },
    async findSessionByThread(threadId) {
      assert.equal(threadId, "thr_runtime_1");
      return { projectId: "proj_runtime", sessionId: "sess_runtime" };
    },
    async getThreadRecord(threadId) {
      assert.equal(threadId, "thr_runtime_1");
      return {
        id: threadId,
        projectId: null,
        cwd: "/hpc/projects/proj_runtime",
        modelProvider: "openai",
        modelId: "gpt-5.3-codex",
        preview: "",
        createdAt: 1,
        updatedAt: 1,
        archived: false,
        statusJson: JSON.stringify({
          modelProvider: "openai",
          model: "gpt-5.3-codex",
          cwd: "/hpc/projects/proj_runtime",
          approvalPolicy: "never",
          sandbox: { mode: "workspace-write" },
          reasoningEffort: null,
          syncState: "ready",
        }),
        engine: "epoch-hpc",
      };
    },
    async readThread(threadId) {
      assert.equal(threadId, "thr_runtime_1");
      return {
        id: threadId,
        preview: "",
        modelProvider: "openai",
        createdAt: 1,
        updatedAt: 1,
        path: null,
        cwd: "/hpc/projects/proj_runtime",
        cliVersion: "epoch/0.1.0",
        source: "appServer",
        gitInfo: null,
        turns: [],
      };
    },
    async appendThreadEvent() {},
    async createTurn() {},
    async updateTurn() {},
    async upsertItem() {},
    async updateThread() {},
    async clearPlanSnapshotForSession() {},
  };

  const engines = {
    defaultEngineName() {
      return "epoch-hpc";
    },
    async getEngine(name) {
      assert.equal(name, "epoch-hpc");
      return {
        name: "epoch-hpc",
        async startTurn(args) {
          const itemId = "item_exec_1";
          const execResponsePromise = deferred();
          return {
            turn: {
              id: args.turnId,
              items: [],
              status: "inProgress",
              error: null,
            },
            events: (async function* stream() {
              yield {
                type: "notification",
                method: "turn/started",
                params: {
                  threadId: args.threadId,
                  turn: { id: args.turnId, items: [], status: "inProgress", error: null },
                },
              };
              yield {
                type: "notification",
                method: "item/started",
                params: {
                  threadId: args.threadId,
                  turnId: args.turnId,
                  item: {
                    type: "commandExecution",
                    id: itemId,
                    command: "echo hello",
                    cwd: args.cwd,
                    processId: null,
                    status: "inProgress",
                    commandActions: [],
                    aggregatedOutput: null,
                    exitCode: null,
                    durationMs: null,
                  },
                },
              };

              yield {
                type: "serverRequest",
                id: "srv_exec_1",
                method: "runtime/commandExecution/exec",
                params: {
                  threadId: args.threadId,
                  turnId: args.turnId,
                  itemId,
                  command: ["/bin/bash", "-c", "echo hello"],
                  cwd: args.cwd,
                },
                respond: async (response) => {
                  execResponsePromise.resolve(response);
                },
              };

              const response = await execResponsePromise.promise;
              const result = response.result ?? {};
              yield {
                type: "notification",
                method: "item/completed",
                params: {
                  threadId: args.threadId,
                  turnId: args.turnId,
                  item: {
                    type: "commandExecution",
                    id: itemId,
                    command: "echo hello",
                    cwd: args.cwd,
                    processId: result.executionId ?? null,
                    status: result.ok ? "completed" : "failed",
                    commandActions: [],
                    aggregatedOutput: `${result.stdout ?? ""}${result.stderr ?? ""}` || null,
                    exitCode: result.exitCode ?? null,
                    durationMs: result.durationMs ?? null,
                  },
                },
              };
              yield {
                type: "notification",
                method: "turn/completed",
                params: {
                  threadId: args.threadId,
                  turn: { id: args.turnId, items: [], status: "completed", error: null },
                },
              };
              turnFinished.resolve();
            })(),
          };
        },
      };
    },
    async close() {},
  };

  const runtimeBridge = {
    isNodeConnected() {
      return true;
    },
    listNodeCommands() {
      return ["runtime.exec.start", "runtime.exec.cancel", "runtime.fs.applyPatch", "runtime.fs.diff"];
    },
    async callNode(method, params) {
      assert.equal(method, "runtime.exec.start");
      assert.equal(params.threadId, "thr_runtime_1");
      assert.equal(params.itemId, "item_exec_1");
      return {
        ok: true,
        exitCode: 0,
        durationMs: 7,
        stdout: "hello\n",
        stderr: "",
        executionId: "exec_123",
      };
    },
    subscribeNodeEvents() {
      return () => {};
    },
    async getSessionPermissionLevel() {
      return "default";
    },
    async reconcileAgentsFile() {},
  };

  const router = new CodexRpcRouter({
    repository,
    engines,
    connection: conn,
    token: "tok_runtime",
    runtimeBridge,
  });

  await router.handleRequest({
    id: "req_init",
    method: "initialize",
    params: { clientInfo: { name: "Epoch", version: "0.1.0" }, capabilities: {} },
  });
  await router.handleNotification({ method: "initialized", params: {} });

  await router.handleRequest({
    id: "req_turn_start",
    method: "turn/start",
    params: {
      threadId: "thr_runtime_1",
      input: [{ type: "text", text: "Run echo", text_elements: [] }],
      planMode: false,
    },
  });

  await turnFinished.promise;

  const deltas = sent.filter((m) => m.method === "item/commandExecution/outputDelta");
  assert.ok(deltas.length > 0);
  assert.ok(String(deltas[0].params.delta).includes("hello"));

  const completed = sent.find((m) => m.method === "item/completed" && m.params?.item?.type === "commandExecution");
  assert.ok(completed);
  assert.equal(completed.params.item.exitCode, 0);
});

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
