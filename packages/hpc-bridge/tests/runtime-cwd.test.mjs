import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";

import { resolveRuntimeCommandCwd } from "../dist/index.js";

test("resolveRuntimeCommandCwd falls back to provided default cwd", () => {
  const cwd = resolveRuntimeCommandCwd({
    workspaceRoot: "/tmp/epoch",
    projectRoot: "/tmp/epoch/projects/proj_1",
    rawCwd: undefined,
    fallbackCwd: "/tmp/epoch/projects/proj_1",
  });
  assert.equal(cwd, path.resolve("/tmp/epoch/projects/proj_1"));
});

test("resolveRuntimeCommandCwd resolves projects/* relative cwd against workspace root", () => {
  const cwd = resolveRuntimeCommandCwd({
    workspaceRoot: "/tmp/epoch",
    projectRoot: "/tmp/epoch/projects/proj_1",
    rawCwd: "projects/proj_1/runs/run_1",
    fallbackCwd: "/tmp/epoch/projects/proj_1",
  });
  assert.equal(cwd, path.resolve("/tmp/epoch/projects/proj_1/runs/run_1"));
});

test("resolveRuntimeCommandCwd resolves non-project relative cwd against project root", () => {
  const cwd = resolveRuntimeCommandCwd({
    workspaceRoot: "/tmp/epoch",
    projectRoot: "/tmp/epoch/projects/proj_1",
    rawCwd: "runs/run_2",
    fallbackCwd: "/tmp/epoch/projects/proj_1",
  });
  assert.equal(cwd, path.resolve("/tmp/epoch/projects/proj_1/runs/run_2"));
});

test("resolveRuntimeCommandCwd preserves absolute cwd", () => {
  const cwd = resolveRuntimeCommandCwd({
    workspaceRoot: "/tmp/epoch",
    projectRoot: "/tmp/epoch/projects/proj_1",
    rawCwd: "/tmp/absolute/workdir",
    fallbackCwd: "/tmp/epoch/projects/proj_1",
  });
  assert.equal(cwd, path.resolve("/tmp/absolute/workdir"));
});
