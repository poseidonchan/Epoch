import test from "node:test";
import assert from "node:assert/strict";

import { handleThreadStart } from "../dist/index.js";

test("handleThreadStart uses a persisted project workspace path when available", async () => {
  const sessionId = "123e4567-e89b-12d3-a456-426614174230";
  const projectId = "123e4567-e89b-12d3-a456-426614174231";
  const chosenWorkspacePath = "/srv/projects/custom-project-root";
  let createdThread = null;

  const repository = {
    stateDirectory() {
      return "/tmp/epoch-thread-state";
    },
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("FROM sessions") && normalized.includes("WHERE id=$1")) {
        assert.equal(args[0], sessionId);
        return [
          {
            id: sessionId,
            project_id: projectId,
            backend_engine: "epoch-hpc",
            codex_model_provider: "openai",
            codex_model: "gpt-5.3-codex",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify({ mode: "workspace-write" }),
          },
        ];
      }
      if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
        assert.equal(args[0], projectId);
        return [{ hpc_workspace_path: chosenWorkspacePath }];
      }
      if (normalized.includes("UPDATE sessions SET codex_thread_id=")) {
        assert.equal(args[2], sessionId);
        return [];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
    async createThread(args) {
      createdThread = args;
    },
    async assignThreadToSession(args) {
      assert.equal(args.sessionId, sessionId);
    },
  };

  const result = await handleThreadStart(
    {
      repository,
      engines: {
        defaultEngineName() {
          return "pi";
        },
        async getEngine() {
          assert.fail("Engine should not be requested for local thread start");
        },
      },
    },
    {
      sessionId,
    }
  );

  assert.equal(result.cwd, chosenWorkspacePath);
  assert.ok(createdThread);
  assert.equal(createdThread.cwd, chosenWorkspacePath);
});

test("handleThreadStart falls back to the default direct-connect workspace root", async () => {
  const projectId = "123e4567-e89b-12d3-a456-426614174232";
  const stateDir = "/tmp/epoch-thread-default-state";
  const expectedCwd = `${stateDir}/workspace/projects/${projectId}`;
  let createdThread = null;

  const originalWorkspaceRoot = process.env.EPOCH_WORKSPACE_ROOT;
  const originalLegacyRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  delete process.env.EPOCH_WORKSPACE_ROOT;
  delete process.env.EPOCH_HPC_WORKSPACE_ROOT;

  try {
    const repository = {
      stateDirectory() {
        return stateDir;
      },
      async query(sql) {
        const normalized = String(sql);
        if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
          return [];
        }
        throw new Error(`Unexpected SQL: ${normalized}`);
      },
      async createThread(args) {
        createdThread = args;
      },
    };

    const result = await handleThreadStart(
      {
        repository,
        engines: {
          defaultEngineName() {
            return "pi";
          },
          async getEngine() {
            assert.fail("Engine should not be requested for local thread start");
          },
        },
      },
      {
        projectId,
      }
    );

    assert.equal(result.cwd, expectedCwd);
    assert.ok(createdThread);
    assert.equal(createdThread.cwd, expectedCwd);
  } finally {
    if (originalWorkspaceRoot == null) {
      delete process.env.EPOCH_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_WORKSPACE_ROOT = originalWorkspaceRoot;
    }
    if (originalLegacyRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalLegacyRoot;
    }
  }
});
