import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { configCommand } from "../dist/index.js";

test("config wizard completes step 5 before lifecycle action runs", async () => {
  const tempHome = await mkdtemp(path.join(os.tmpdir(), "bridge-home-"));
  const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), "bridge-workspace-"));
  const oldHome = process.env.HOME;
  process.env.HOME = tempHome;

  const events = [];
  const ui = {
    interactive: true,
    banner() {},
    step(index, _total, message) {
      events.push(`step:${index}:${message}`);
    },
    line() {},
    note(message) {
      events.push(`note:${message}`);
    },
    warn(message) {
      events.push(`warn:${message}`);
    },
    error(message) {
      events.push(`error:${message}`);
    },
    success(message) {
      events.push(`success:${message}`);
    },
    keyValue() {},
    summary() {},
  };

  const prompter = {
    interactive: true,
    async input(opts) {
      if (opts.message === "Hub WS URL") return "ws://127.0.0.1:8787/ws";
      if (opts.message === "Workspace root") return workspaceRoot;
      return "";
    },
    async secret() {
      return "test-shared-token";
    },
    async confirm(opts) {
      if (opts.message.includes("Run quick Hub connectivity check")) return false;
      if (opts.message.includes("Start LabOS HPC bridge now?")) return true;
      return true;
    },
    close() {},
  };

  try {
    await configCommand([], {
      mode: "config",
      ui,
      prompter,
      onLifecycleAction: async ({ action }) => {
        events.push(`lifecycle:${action}`);
      },
    });
  } finally {
    if (oldHome == null) {
      delete process.env.HOME;
    } else {
      process.env.HOME = oldHome;
    }
  }

  const wizardCompleteIndex = events.findIndex((entry) => entry.includes("step:5:Wizard complete"));
  const lifecycleIndex = events.findIndex((entry) => entry.startsWith("lifecycle:"));
  assert.ok(wizardCompleteIndex >= 0, "expected wizard completion step");
  assert.ok(lifecycleIndex >= 0, "expected lifecycle action");
  assert.ok(wizardCompleteIndex < lifecycleIndex, "step 5 should be emitted before lifecycle action");
  assert.match(events[lifecycleIndex], /lifecycle:start|lifecycle:restart/);
});
