import test from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);
const BRIDGE_CLI = path.resolve("dist/cli.js");

function runBridge(args, env = {}) {
  return execFileAsync(process.execPath, [BRIDGE_CLI, ...args], {
    env: { ...process.env, ...env },
  });
}

test("hpc bridge --help includes init/config/restart/stop", async () => {
  const { stdout } = await runBridge(["--help"]);
  assert.match(stdout, /init\|config\|pair\|start\|restart\|stop\|status\|doctor/);
});

test("hpc bridge start missing config points users to config command", async () => {
  const tempHome = await mkdtemp(path.join(os.tmpdir(), "hpc-cli-home-"));
  let failed = false;
  try {
    await runBridge(["start"], { HOME: tempHome });
  } catch (err) {
    failed = true;
    const stderr = String(err.stderr ?? "");
    assert.match(stderr, /Config missing\. Run: epoch-bridge config/);
  }
  assert.equal(failed, true);
});
