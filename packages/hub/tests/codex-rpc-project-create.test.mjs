import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { handleEpochProjectCreate } from "../dist/index.js";

test("handleEpochProjectCreate provisions direct-connect workspace immediately and marks it ready", async () => {
  const originalWorkspaceRoot = process.env.EPOCH_WORKSPACE_ROOT;
  const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), "epoch-workspace-root-"));
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-project-create-state-"));
  const chosenWorkspacePath = path.join(workspaceRoot, "user-picked-project");
  process.env.EPOCH_WORKSPACE_ROOT = workspaceRoot;

  let insertedProjectArgs = null;
  let queuedProvisioning = false;

  const repository = {
    stateDirectory() {
      return stateDir;
    },
    async ensureProjectStorage() {},
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT hpc_workspace_path FROM projects")) {
        return [];
      }
      if (normalized.includes("INSERT INTO workspace_provisioning_queue")) {
        queuedProvisioning = true;
        return [];
      }
      if (normalized.includes("INSERT INTO projects")) {
        insertedProjectArgs = args;
        return [];
      }
      if (normalized.includes("FROM projects") && normalized.includes("WHERE id=$1")) {
        return [
          {
            id: insertedProjectArgs[0],
            name: insertedProjectArgs[1],
            created_at: insertedProjectArgs[2],
            updated_at: insertedProjectArgs[3],
            backend_engine: insertedProjectArgs[4],
            codex_model_provider: insertedProjectArgs[5],
            codex_model_id: insertedProjectArgs[6],
            codex_approval_policy: insertedProjectArgs[7],
            codex_sandbox_json: insertedProjectArgs[8],
            hpc_workspace_path: insertedProjectArgs[9],
            hpc_workspace_state: insertedProjectArgs[10],
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  try {
    const result = await handleEpochProjectCreate(
      {
        repository,
        engines: {},
      },
      {
        name: "Direct Project",
        workspacePath: chosenWorkspacePath,
      }
    );

    assert.equal(queuedProvisioning, false);
    assert.equal(insertedProjectArgs[10], "ready");
    assert.equal(result.project.hpcWorkspacePath, chosenWorkspacePath);
    assert.equal(result.project.hpcWorkspaceState, "ready");
  } finally {
    if (originalWorkspaceRoot == null) delete process.env.EPOCH_WORKSPACE_ROOT;
    else process.env.EPOCH_WORKSPACE_ROOT = originalWorkspaceRoot;
  }
});

test("handleEpochProjectCreate expands tilde-rooted workspace paths before persisting them", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-project-create-tilde-state-"));
  const chosenWorkspacePath = "~/Documents/GitHub";
  const expectedWorkspacePath = path.join(os.homedir(), "Documents", "GitHub");

  let insertedProjectArgs = null;

  const repository = {
    stateDirectory() {
      return stateDir;
    },
    async ensureProjectStorage() {},
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("SELECT hpc_workspace_path FROM projects")) {
        return [];
      }
      if (normalized.includes("INSERT INTO projects")) {
        insertedProjectArgs = args;
        return [];
      }
      if (normalized.includes("FROM projects") && normalized.includes("WHERE id=$1")) {
        return [
          {
            id: insertedProjectArgs[0],
            name: insertedProjectArgs[1],
            created_at: insertedProjectArgs[2],
            updated_at: insertedProjectArgs[3],
            backend_engine: insertedProjectArgs[4],
            codex_model_provider: insertedProjectArgs[5],
            codex_model_id: insertedProjectArgs[6],
            codex_approval_policy: insertedProjectArgs[7],
            codex_sandbox_json: insertedProjectArgs[8],
            hpc_workspace_path: insertedProjectArgs[9],
            hpc_workspace_state: insertedProjectArgs[10],
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const result = await handleEpochProjectCreate(
    {
      repository,
      engines: {},
    },
    {
      name: "Home Project",
      workspacePath: chosenWorkspacePath,
    }
  );

  assert.equal(insertedProjectArgs[9], expectedWorkspacePath);
  assert.equal(result.project.hpcWorkspacePath, expectedWorkspacePath);
});

test("handleEpochProjectCreate rejects relative workspace paths that are not tilde-rooted", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-project-create-relative-state-"));
  let inserted = false;

  const repository = {
    stateDirectory() {
      return stateDir;
    },
    async ensureProjectStorage() {},
    async query(sql) {
      if (String(sql).includes("INSERT INTO projects")) {
        inserted = true;
      }
      throw new Error(`Unexpected SQL: ${String(sql)}`);
    },
  };

  await assert.rejects(
    () =>
      handleEpochProjectCreate(
        {
          repository,
          engines: {},
        },
        {
          name: "Relative Project",
          workspacePath: "Documents/GitHub",
        }
      ),
    /workspacePath/i
  );

  assert.equal(inserted, false);
});
