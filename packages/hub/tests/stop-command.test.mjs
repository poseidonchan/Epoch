import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const HUB_CLI = path.resolve("dist/cli.js");

function runHub(args, env = {}) {
  return execFileAsync(process.execPath, [HUB_CLI, ...args], {
    env: { ...process.env, ...env },
  });
}

test("hub stop is safe when daemon not running", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-stop-none-"));
  const { stdout } = await runHub(["stop"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /already stopped|No running Epoch Hub daemon found/i);
});

test("hub stop cleans stale pid metadata", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-stop-stale-"));
  const pidPath = path.join(stateDir, "hub.pid");
  await writeFile(
    pidPath,
    JSON.stringify({ pid: 999999, startedAt: new Date().toISOString(), host: "0.0.0.0", port: 8787, logPath: path.join(stateDir, "hub.log") }) + "\n",
    "utf8"
  );

  const { stdout } = await runHub(["stop"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /already stopped|stopped|No running Epoch Hub daemon found/i);

  let removed = false;
  try {
    await readFile(pidPath, "utf8");
  } catch {
    removed = true;
  }
  assert.equal(removed, true);
});

test("hub stop treats invalid daemon json as not running", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-stop-invalid-"));
  const pidPath = path.join(stateDir, "hub.pid");
  await writeFile(pidPath, JSON.stringify({ pid: "invalid" }) + "\n", "utf8");

  const { stdout } = await runHub(["stop"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /already stopped|No running Epoch Hub daemon found/i);
});
