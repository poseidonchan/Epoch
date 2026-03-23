import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { LocalRuntimeBridge } from "../dist/index.js";

test("LocalRuntimeBridge provisions project workspace and supports local runtime operations", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-local-runtime-state-"));
  const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), "epoch-local-runtime-workspace-"));
  const chosenWorkspacePath = path.join(workspaceRoot, "chosen-folder");

  const runtime = new LocalRuntimeBridge({
    stateDir,
    workspaceRoot,
  });

  const events = [];
  const unsubscribe = runtime.subscribeNodeEvents((event, payload) => {
    events.push({ event, payload });
  });

  const ensureResult = await runtime.callNode("workspace.project.ensure", {
    projectId: "proj_local_runtime",
    workspacePath: chosenWorkspacePath,
  });

  assert.equal(ensureResult.ok, true);
  assert.equal(ensureResult.workspacePath, chosenWorkspacePath);
  await stat(path.join(chosenWorkspacePath, "artifacts"));

  const writeResult = await runtime.callNode("runtime.fs.write", {
    projectId: "proj_local_runtime",
    path: "notes.txt",
    data: "alpha\n",
    encoding: "utf8",
    permissionLevel: "full",
  });
  assert.equal(writeResult.ok, true);

  const execPromise = runtime.callNode("runtime.exec.start", {
    projectId: "proj_local_runtime",
    sessionId: "sess_local_runtime",
    threadId: "thr_local_runtime",
    turnId: "turn_local_runtime",
    itemId: "item_local_runtime",
    executionId: "exec_local_runtime",
    command: ["/bin/sh", "-c", "printf 'beta\\n' >> notes.txt"],
    cwd: ".",
    permissionLevel: "full",
  });
  const execResult = await execPromise;
  assert.equal(execResult.ok, true);
  assert.equal(execResult.exitCode, 0);

  const patchResult = await runtime.callNode("runtime.fs.applyPatch", {
    projectId: "proj_local_runtime",
    sessionId: "sess_local_runtime",
    threadId: "thr_local_runtime",
    turnId: "turn_local_runtime",
    itemId: "item_patch_local_runtime",
    patchId: "patch_local_runtime",
    patch: [
      "diff --git a/notes.txt b/notes.txt",
      "--- a/notes.txt",
      "+++ b/notes.txt",
      "@@ -1,2 +1,2 @@",
      " alpha",
      "-beta",
      "+gamma",
      "",
    ].join("\n"),
    permissionLevel: "full",
  });
  assert.equal(patchResult.applied, true);

  const readResult = await runtime.callNode("runtime.fs.read", {
    projectId: "proj_local_runtime",
    path: "notes.txt",
    offset: 0,
    length: 1024,
    encoding: "utf8",
  });
  assert.equal(readResult.data, "alpha\ngamma");

  const diffResult = await runtime.callNode("runtime.fs.diff", {
    projectId: "proj_local_runtime",
    paths: ["notes.txt"],
  });
  assert.equal(typeof diffResult.diff, "string");
  assert.match(patchResult.diff, /gamma/);

  const snapshot = await runtime.resourceSnapshot();
  assert.equal(snapshot.computeConnected, true);
  assert.equal(Object.prototype.hasOwnProperty.call(snapshot, "queueDepth"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(snapshot, "hpc"), false);
  assert.equal(typeof snapshot.storageAvailableBytes, "number");
  assert.equal(typeof snapshot.cpuPercent, "number");
  assert.equal(typeof snapshot.ramPercent, "number");

  assert.equal(events.some((entry) => entry.event === "runtime.exec.completed"), true);
  assert.equal(events.some((entry) => entry.event === "runtime.fs.patchCompleted"), true);
  assert.equal(await readFile(path.join(chosenWorkspacePath, "notes.txt"), "utf8"), "alpha\ngamma");

  unsubscribe();
});
