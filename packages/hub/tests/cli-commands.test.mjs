import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);
const HUB_CLI = path.resolve("dist/cli.js");

function runHub(args, env = {}) {
  return execFileAsync(process.execPath, [HUB_CLI, ...args], {
    env: { ...process.env, ...env },
  });
}

test("hub --help includes stop and status", async () => {
  const { stdout } = await runHub(["--help"]);
  assert.match(stdout, /init\|config\|start\|restart\|stop\|status\|doctor/);
});

test("hub status shows daemon-aware status output", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-status-"));
  const { stdout } = await runHub(["status"], { LABOS_STATE_DIR: stateDir });
  assert.match(stdout, /LabOS Hub Status/);
  assert.match(stdout, /Config:\s+missing \(run labos-hub init\)/i);
  assert.match(stdout, /Daemon:\s+stopped/i);
});

test("hub status normalizes daemon metadata defaults", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-status-defaults-"));
  const pidPath = path.join(stateDir, "hub.pid");
  await writeFile(pidPath, JSON.stringify({ pid: process.pid }) + "\n", "utf8");

  const { stdout } = await runHub(["status"], { LABOS_STATE_DIR: stateDir });
  assert.match(stdout, /Daemon:\s+running \(pid/i);
  assert.match(stdout, /Host:\s+0\.0\.0\.0/);
  assert.match(stdout, /Port:\s+8787/);
  assert.match(stdout, /Log path:\s+.*hub\.log/);
});
