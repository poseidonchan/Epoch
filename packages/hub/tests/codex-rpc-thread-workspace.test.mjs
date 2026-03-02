import test from "node:test";
import assert from "node:assert/strict";

import { handleThreadStart } from "../dist/index.js";

test("handleThreadStart fails fast when workspace root is unavailable for project sessions", async () => {
  const originalRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  delete process.env.EPOCH_HPC_WORKSPACE_ROOT;

  const sessionId = "123e4567-e89b-12d3-a456-426614174230";
  const projectId = "123e4567-e89b-12d3-a456-426614174231";

  try {
    const repository = {
      async query(sql, args = []) {
        const normalized = String(sql);
        if (normalized.includes("FROM sessions") && normalized.includes("WHERE id=$1")) {
          assert.equal(args[0], sessionId);
          return [
            {
              id: sessionId,
              project_id: projectId,
              backend_engine: "codex-app-server",
              codex_model_provider: "openai",
              codex_model: "gpt-5.3-codex",
              codex_approval_policy: "on-request",
              codex_sandbox_json: JSON.stringify({ mode: "workspace-write" }),
            },
          ];
        }
        if (normalized.includes("FROM nodes")) {
          return [];
        }
        throw new Error(`Unexpected SQL: ${normalized}`);
      },
    };

    await assert.rejects(
      () =>
        handleThreadStart(
          {
            repository,
            engines: {
              defaultEngineName() {
                return "codex-app-server";
              },
              async getEngine() {
                assert.fail("Engine should not be requested when workspace root is missing");
              },
            },
          },
          {
            sessionId,
          }
        ),
      /CAPABILITY_MISSING: node workspaceRoot is unavailable/
    );
  } finally {
    if (originalRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalRoot;
    }
  }
});

test("handleThreadStart resolves workspace root from nodes table when env is unavailable", async () => {
  const originalRoot = process.env.EPOCH_HPC_WORKSPACE_ROOT;
  delete process.env.EPOCH_HPC_WORKSPACE_ROOT;

  const projectId = "123e4567-e89b-12d3-a456-426614174232";
  const workspaceRoot = "/tmp/epoch-from-node";
  let createdThread = null;

  try {
    const repository = {
      async query(sql) {
        const normalized = String(sql);
        if (normalized.includes("FROM nodes")) {
          return [
            {
              permissions: JSON.stringify({ workspaceRoot }),
            },
          ];
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

    const expectedCwd = `${workspaceRoot}/projects/${projectId}`;
    assert.equal(result.cwd, expectedCwd);
    assert.ok(createdThread);
    assert.equal(createdThread.cwd, expectedCwd);
  } finally {
    if (originalRoot == null) {
      delete process.env.EPOCH_HPC_WORKSPACE_ROOT;
    } else {
      process.env.EPOCH_HPC_WORKSPACE_ROOT = originalRoot;
    }
  }
});
