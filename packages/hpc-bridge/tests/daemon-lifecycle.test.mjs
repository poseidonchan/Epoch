import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { bridgePidPath, readBridgeDaemonInfo, stopBridgeDaemon } from "../dist/index.js";

test("stopBridgeDaemon is safe with missing pid file", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "bridge-daemon-none-"));
  const result = await stopBridgeDaemon(stateDir);
  assert.deepEqual(result, { stopped: false });
});

test("stopBridgeDaemon cleans stale pid metadata", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "bridge-daemon-stale-"));
  const pidPath = bridgePidPath(stateDir);
  await writeFile(
    pidPath,
    JSON.stringify({ pid: 999999, startedAt: new Date().toISOString(), logPath: path.join(stateDir, "bridge.log") }) + "\n",
    "utf8"
  );

  const before = await readBridgeDaemonInfo(stateDir);
  assert.ok(before);

  const result = await stopBridgeDaemon(stateDir);
  assert.equal(result.stopped, false);

  let removed = false;
  try {
    await readFile(pidPath, "utf8");
  } catch {
    removed = true;
  }
  assert.equal(removed, true);
});

test("readBridgeDaemonInfo normalizes missing metadata fields", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "bridge-daemon-defaults-"));
  const pidPath = bridgePidPath(stateDir);
  await writeFile(pidPath, JSON.stringify({ pid: process.pid }) + "\n", "utf8");

  const info = await readBridgeDaemonInfo(stateDir);
  assert.ok(info);
  assert.equal(info?.pid, process.pid);
  assert.match(String(info?.startedAt), /\d{4}-\d{2}-\d{2}T/);
  assert.match(String(info?.logPath), /bridge\.log$/);
});

test("readBridgeDaemonInfo returns null for invalid daemon pid json", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "bridge-daemon-invalid-"));
  const pidPath = bridgePidPath(stateDir);
  await writeFile(pidPath, JSON.stringify({ pid: "oops" }) + "\n", "utf8");

  const info = await readBridgeDaemonInfo(stateDir);
  assert.equal(info, null);
});
