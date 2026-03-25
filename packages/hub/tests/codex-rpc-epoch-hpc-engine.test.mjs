import test from "node:test";
import assert from "node:assert/strict";

import { CodexEngineRegistry } from "../dist/index.js";

test("epoch-hpc modelList returns only openai-codex models by default", async () => {
  const previousPrimary = process.env.EPOCH_MODEL_PRIMARY;
  const previousModel = process.env.EPOCH_MODEL;
  delete process.env.EPOCH_MODEL_PRIMARY;
  delete process.env.EPOCH_MODEL;

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const result = await engine.modelList({});
    assert.ok(Array.isArray(result.data));
    assert.ok(result.data.some((entry) => entry.id === "gpt-5.3-codex"));
    assert.ok(result.data.every((entry) => entry.provider === "openai-codex"));
    assert.ok(!result.data.some((entry) => String(entry.id).startsWith("claude-")));
  } finally {
    if (previousPrimary == null) delete process.env.EPOCH_MODEL_PRIMARY;
    else process.env.EPOCH_MODEL_PRIMARY = previousPrimary;
    if (previousModel == null) delete process.env.EPOCH_MODEL;
    else process.env.EPOCH_MODEL = previousModel;
    await registry.close();
  }
});

test("epoch-hpc modelList follows the configured primary provider", async () => {
  const previousPrimary = process.env.EPOCH_MODEL_PRIMARY;
  const previousModel = process.env.EPOCH_MODEL;
  process.env.EPOCH_MODEL_PRIMARY = "anthropic/claude-sonnet-4.5";
  delete process.env.EPOCH_MODEL;

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const result = await engine.modelList({});
    assert.ok(Array.isArray(result.data));
    assert.ok(result.data.some((entry) => String(entry.id).startsWith("claude-")));
    assert.ok(result.data.every((entry) => entry.provider === "anthropic"));
    assert.ok(!result.data.some((entry) => entry.id === "gpt-5.3-codex"));
  } finally {
    if (previousPrimary == null) delete process.env.EPOCH_MODEL_PRIMARY;
    else process.env.EPOCH_MODEL_PRIMARY = previousPrimary;
    if (previousModel == null) delete process.env.EPOCH_MODEL;
    else process.env.EPOCH_MODEL = previousModel;
    await registry.close();
  }
});

test("epoch-hpc uses developer role and streams deltas via SSE", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  const fetchCalls = [];
  const completionGate = deferred();

  globalThis.fetch = async (url, init) => {
    fetchCalls.push({ url: String(url), init });
    const body = JSON.parse(String(init?.body ?? "{}"));
    assert.equal(body.stream, true);
    assert.equal(body.input?.[0]?.role, "developer");
    assert.ok(String(body.input?.[0]?.content?.[0]?.text ?? "").includes("DEV_INSTRUCTIONS"));

    const encoder = new TextEncoder();
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(encoder.encode(`data: ${JSON.stringify({ type: "response.output_text.delta", delta: "Hello" })}\n\n`));
        completionGate.promise.then(() => {
          controller.enqueue(
            encoder.encode(
              `data: ${JSON.stringify({
                type: "response.completed",
                response: { id: "resp_1", output_text: "Hello", output: [] },
              })}\n\n`
            )
          );
          controller.close();
        });
      },
    });

    return new Response(stream, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  };

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_sse_1",
      turnId: "turn_sse_1",
      input: [{ type: "text", text: "hi", text_elements: [] }],
      historyTurns: [],
      cwd: "/hpc/project",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "never",
      collaborationMode: {
        mode: "default",
        settings: {
          model: "gpt-5.3-codex",
          reasoning_effort: null,
          developer_instructions: "DEV_INSTRUCTIONS",
        },
      },
      sandboxPolicy: null,
    });

    const iter = started.events[Symbol.asyncIterator]();
    const firstDelta = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "item/agentMessage/delta");
    assert.equal(firstDelta.params.delta, "Hello");

    // The stream is still open; we should see delta before turn completion is possible.
    completionGate.resolve();

    const completed = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completed.params.turn.status, "completed");
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }

  assert.equal(fetchCalls.length, 1);
});

test("epoch-hpc executes multiple tool calls in parallel when approvalPolicy=never", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  let callIndex = 0;
  globalThis.fetch = async () => {
    callIndex += 1;
    if (callIndex === 1) {
      return new Response(
        JSON.stringify({
          id: "resp_1",
          output_text: "",
          output: [
            { type: "function_call", name: "exec_command", call_id: "call_1", arguments: JSON.stringify({ cmd: "echo 1" }) },
            { type: "function_call", name: "exec_command", call_id: "call_2", arguments: JSON.stringify({ cmd: "echo 2" }) },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        id: "resp_2",
        output_text: "done",
        output: [],
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  };

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_parallel_1",
      turnId: "turn_parallel_1",
      input: [{ type: "text", text: "run", text_elements: [] }],
      historyTurns: [],
      cwd: "/hpc/project",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "never",
      collaborationMode: {
        mode: "default",
        settings: {
          model: "gpt-5.3-codex",
          reasoning_effort: null,
          developer_instructions: "DEV",
        },
      },
      sandboxPolicy: null,
    });

    const iter = started.events[Symbol.asyncIterator]();
    const runtimeRequests = [];

    while (runtimeRequests.length < 2) {
      const next = await Promise.race([iter.next(), timeout(750)]);
      assert.ok(next && typeof next === "object" && "done" in next);
      assert.equal(next.done, false, "event stream ended before emitting both runtime requests");
      const event = next.value;
      if (event.type === "serverRequest") {
        if (event.method === "runtime/commandExecution/exec") {
          runtimeRequests.push(event);
          continue;
        }
        if (event.respond) await event.respond({ result: {} });
      }
    }

    // If tool calls were sequential, we would never have reached 2 without responding to the first.
    await runtimeRequests[0].respond({
      result: { ok: true, exitCode: 0, durationMs: 1, stdout: "one\n", stderr: "", executionId: "exec_1" },
    });
    await runtimeRequests[1].respond({
      result: { ok: true, exitCode: 0, durationMs: 1, stdout: "two\n", stderr: "", executionId: "exec_2" },
    });

    const completed = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completed.params.turn.status, "completed");
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }
});

test("epoch-hpc apply_patch emits applied fileChange item", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  let callIndex = 0;
  globalThis.fetch = async () => {
    callIndex += 1;
    if (callIndex === 1) {
      return new Response(
        JSON.stringify({
          id: "resp_patch_1",
          output_text: "",
          output: [
            {
              type: "function_call",
              name: "apply_patch",
              call_id: "call_patch_1",
              arguments: JSON.stringify({ patch: "*** Begin Patch\n*** End Patch\n" }),
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ id: "resp_patch_2", output_text: "ok", output: [] }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  };

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_patch_1",
      turnId: "turn_patch_1",
      input: [{ type: "text", text: "patch", text_elements: [] }],
      historyTurns: [],
      cwd: "/hpc/project",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "never",
      collaborationMode: {
        mode: "default",
        settings: { model: "gpt-5.3-codex", reasoning_effort: null, developer_instructions: "DEV" },
      },
      sandboxPolicy: null,
    });

    const iter = started.events[Symbol.asyncIterator]();
    const patchRequest = await waitForEvent(iter, (evt) => evt.type === "serverRequest" && evt.method === "runtime/fileChange/applyPatch");
    await patchRequest.respond({
      result: { ok: true, applied: true, changedPaths: ["foo.txt"], diff: "diff --git a/foo.txt b/foo.txt\n" },
    });

    const completedItem = await waitForEvent(
      iter,
      (evt) => evt.type === "notification" && evt.method === "item/completed" && evt.params?.item?.type === "fileChange"
    );
    assert.equal(completedItem.params.item.status, "applied");

    const completedTurn = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completedTurn.params.turn.status, "completed");
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }
});

test("epoch-hpc approval decline returns declined tool result and completes item interrupted", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  let callIndex = 0;
  globalThis.fetch = async () => {
    callIndex += 1;
    if (callIndex === 1) {
      return new Response(
        JSON.stringify({
          id: "resp_decline_1",
          output_text: "",
          output: [{ type: "function_call", name: "exec_command", call_id: "call_decline_1", arguments: JSON.stringify({ cmd: "echo no" }) }],
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ id: "resp_decline_2", output_text: "ok", output: [] }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  };

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_decline_1",
      turnId: "turn_decline_1",
      input: [{ type: "text", text: "decline", text_elements: [] }],
      historyTurns: [],
      cwd: "/hpc/project",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "on-request",
      collaborationMode: {
        mode: "default",
        settings: { model: "gpt-5.3-codex", reasoning_effort: null, developer_instructions: "DEV" },
      },
      sandboxPolicy: null,
    });

    const iter = started.events[Symbol.asyncIterator]();
    const approvalReq = await waitForEvent(iter, (evt) => evt.type === "serverRequest" && evt.method === "item/commandExecution/requestApproval");
    await approvalReq.respond({ result: { decision: "decline" } });

    const completedItem = await waitForEvent(
      iter,
      (evt) => evt.type === "notification" && evt.method === "item/completed" && evt.params?.item?.type === "commandExecution"
    );
    assert.equal(completedItem.params.item.status, "interrupted");
    assert.ok(String(completedItem.params.item.aggregatedOutput).toLowerCase().includes("declined"));

    const completedTurn = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completedTurn.params.turn.status, "completed");
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }
});

test("epoch-hpc skips approval and forwards danger-full-access sandboxMode for exec_command", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  let callIndex = 0;
  globalThis.fetch = async () => {
    callIndex += 1;
    if (callIndex === 1) {
      return new Response(
        JSON.stringify({
          id: "resp_full_access_1",
          output_text: "",
          output: [{ type: "function_call", name: "exec_command", call_id: "call_full_access_1", arguments: JSON.stringify({ cmd: "echo ok" }) }],
        }),
        { status: 200, headers: { "content-type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ id: "resp_full_access_2", output_text: "ok", output: [] }),
      { status: 200, headers: { "content-type": "application/json" } }
    );
  };

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_full_access_1",
      turnId: "turn_full_access_1",
      input: [{ type: "text", text: "full access", text_elements: [] }],
      historyTurns: [],
      cwd: "/hpc/project",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "on-request",
      collaborationMode: {
        mode: "default",
        settings: { model: "gpt-5.3-codex", reasoning_effort: null, developer_instructions: "DEV" },
      },
      sandboxPolicy: { type: "danger-full-access" },
    });

    const iter = started.events[Symbol.asyncIterator]();
    const runtimeReq = await waitForEvent(iter, (evt) => evt.type === "serverRequest");
    assert.equal(runtimeReq.method, "runtime/commandExecution/exec");
    assert.equal(runtimeReq.params.sandboxMode, "danger-full-access");
    await runtimeReq.respond({ result: { ok: true, exitCode: 0, durationMs: 1, stdout: "ok\n", stderr: "", executionId: "exec_full_access" } });

    const completedTurn = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completedTurn.params.turn.status, "completed");
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }
});

test("epoch-hpc ENOENT runtime error includes additionalDetails hint", async () => {
  const originalFetch = globalThis.fetch;
  const originalKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";

  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        id: "resp_enoent_1",
        output_text: "",
        output: [{ type: "function_call", name: "exec_command", call_id: "call_enoent_1", arguments: JSON.stringify({ cmd: "pwd" }) }],
      }),
      { status: 200, headers: { "content-type": "application/json" } }
    );

  const registry = new CodexEngineRegistry({ config: null, stateDir: "/tmp" });
  try {
    const engine = await registry.getEngine("epoch-hpc");
    const started = await engine.startTurn({
      threadId: "thr_enoent_1",
      turnId: "turn_enoent_1",
      input: [{ type: "text", text: "enoent", text_elements: [] }],
      historyTurns: [],
      cwd: "/missing/cwd",
      model: "gpt-5.3-codex",
      modelProvider: "openai",
      approvalPolicy: "never",
      collaborationMode: {
        mode: "default",
        settings: { model: "gpt-5.3-codex", reasoning_effort: null, developer_instructions: "DEV" },
      },
      sandboxPolicy: null,
    });

    const iter = started.events[Symbol.asyncIterator]();
    const runtimeReq = await waitForEvent(iter, (evt) => evt.type === "serverRequest" && evt.method === "runtime/commandExecution/exec");
    await runtimeReq.respond({ error: { code: -32000, message: "ENOENT: no such file or directory" } });

    const completedTurn = await waitForEvent(iter, (evt) => evt.type === "notification" && evt.method === "turn/completed");
    assert.equal(completedTurn.params.turn.status, "failed");
    const details = String(completedTurn.params.turn.error.additionalDetails ?? "");
    assert.ok(details.includes("engineName=epoch-hpc"));
    assert.ok(details.includes("method=runtime/commandExecution/exec"));
    assert.ok(details.includes("cwd=/missing/cwd"));
    assert.ok(details.includes("command[0]=/bin/bash"));
    assert.ok(details.toLowerCase().includes("workspace path"));
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENAI_API_KEY = originalKey;
    await registry.close();
  }
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

function timeout(ms) {
  return new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout after ${ms}ms`)), ms));
}

async function waitForEvent(iter, predicate) {
  while (true) {
    const next = await iter.next();
    if (next.done) {
      throw new Error("Event stream ended unexpectedly");
    }
    const event = next.value;
    if (predicate(event)) {
      return event;
    }
    if (event.type === "serverRequest" && event.respond) {
      await event.respond({ result: {} });
    }
  }
}
