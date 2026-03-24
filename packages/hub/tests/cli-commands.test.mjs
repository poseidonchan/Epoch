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
  assert.match(stdout, /Usage:\s+epoch\s+</i);
});

test("hub status shows daemon-aware status output", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-status-"));
  const { stdout } = await runHub(["status"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /Epoch Server Status/);
  assert.match(stdout, /Config:\s+missing \(run epoch init\)/i);
  assert.match(stdout, /Daemon:\s+stopped/i);
  assert.doesNotMatch(stdout, /Background push/i);
  assert.doesNotMatch(stdout, /Encrypted APNs key/i);
  assert.doesNotMatch(stdout, /Unlock required on start/i);
});

test("hub status --qr prints epoch pairing payload with display name", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-status-qr-"));
  await writeFile(
    path.join(stateDir, "config.json"),
    JSON.stringify(
      {
        serverId: "srv_status_qr",
        token: "tok_status_qr",
        createdAt: "2026-03-23T00:00:00.000Z",
        displayName: "Tailnet Login",
        publicWsUrl: "ws://login01.epoch.ts.net:8787/ws",
      },
      null,
      2
    ) + "\n",
    "utf8"
  );

  const { stdout } = await runHub(["status", "--qr"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /Pairing URL \(fallback\):/);
  assert.match(stdout, /epoch:\/\/pair\?v=1/);
  assert.match(stdout, /name=Tailnet\+Login/);
  assert.match(stdout, /serverId=srv_status_qr/);
});

test("hub status normalizes daemon metadata defaults", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-status-defaults-"));
  const pidPath = path.join(stateDir, "hub.pid");
  await writeFile(pidPath, JSON.stringify({ pid: process.pid }) + "\n", "utf8");

  const { stdout } = await runHub(["status"], { EPOCH_STATE_DIR: stateDir });
  assert.match(stdout, /Daemon:\s+running \(pid/i);
  assert.match(stdout, /Host:\s+0\.0\.0\.0/);
  assert.match(stdout, /Port:\s+8787/);
  assert.match(stdout, /Log path:\s+.*hub\.log/);
  assert.doesNotMatch(stdout, /Background push/i);
  assert.doesNotMatch(stdout, /Encrypted APNs key/i);
});

test("hub doctor no longer mentions APNs or push setup", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "hub-doctor-"));
  const stdout = await runHub(["doctor"], { EPOCH_STATE_DIR: stateDir })
    .then((result) => result.stdout)
    .catch((error) => error.stdout ?? "");

  assert.match(stdout, /Config:\s+missing \(run epoch init\)/i);
  assert.doesNotMatch(stdout, /Background push/i);
  assert.doesNotMatch(stdout, /Push topic/i);
  assert.doesNotMatch(stdout, /APNs/i);
});
