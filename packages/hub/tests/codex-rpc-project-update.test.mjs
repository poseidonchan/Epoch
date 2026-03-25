import test from "node:test";
import assert from "node:assert/strict";

import { handleEpochProjectUpdate } from "../dist/index.js";

test("handleEpochProjectUpdate patches codex policy+sandbox and returns mapped project", async () => {
  const projectId = "123e4567-e89b-12d3-a456-426614174222";
  const expectedSandbox = { type: "danger-full-access" };

  let capturedUpdateSql = "";
  let capturedUpdateArgs = [];

  const repository = {
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("UPDATE projects")) {
        capturedUpdateSql = normalized;
        capturedUpdateArgs = args;
        return [];
      }
      if (normalized.includes("FROM projects") && normalized.includes("WHERE id=$1")) {
        return [
          {
            id: projectId,
            name: "Permission Project",
            created_at: "2026-02-01T00:00:00.000Z",
            updated_at: "2026-02-02T00:00:00.000Z",
            backend_engine: "codex-app-server",
            codex_model_provider: "openai",
            codex_model_id: "gpt-5.3-codex",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify(expectedSandbox),
            hpc_workspace_path: null,
            hpc_workspace_state: "queued",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const result = await handleEpochProjectUpdate(
    {
      repository,
      engines: {},
    },
    {
      projectId,
      codexApprovalPolicy: "never",
      codexSandbox: expectedSandbox,
    }
  );

  assert.ok(capturedUpdateSql.includes("codex_approval_policy="));
  assert.ok(capturedUpdateSql.includes("codex_sandbox_json="));
  assert.equal(capturedUpdateArgs[0], "never");
  assert.equal(JSON.parse(capturedUpdateArgs[1]).type, "danger-full-access");

  assert.equal(result.project.id, projectId);
  assert.equal(result.project.codexApprovalPolicy, "on-request");
  assert.deepEqual(result.project.codexSandbox, expectedSandbox);
});

test("handleEpochProjectUpdate accepts legacy mode sandbox payloads and rewrites them to type shape", async () => {
  const projectId = "123e4567-e89b-12d3-a456-426614174223";
  const legacySandbox = { mode: "danger-full-access" };
  const expectedSandbox = { type: "danger-full-access" };

  let capturedUpdateArgs = [];

  const repository = {
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("UPDATE projects")) {
        capturedUpdateArgs = args;
        return [];
      }
      if (normalized.includes("FROM projects") && normalized.includes("WHERE id=$1")) {
        return [
          {
            id: projectId,
            name: "Legacy Sandbox Project",
            created_at: "2026-02-01T00:00:00.000Z",
            updated_at: "2026-02-02T00:00:00.000Z",
            backend_engine: "codex-app-server",
            codex_model_provider: "openai",
            codex_model_id: "gpt-5.3-codex",
            codex_approval_policy: "on-request",
            codex_sandbox_json: JSON.stringify(expectedSandbox),
            hpc_workspace_path: null,
            hpc_workspace_state: "queued",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const result = await handleEpochProjectUpdate(
    {
      repository,
      engines: {},
    },
    {
      projectId,
      codexApprovalPolicy: "on-request",
      codexSandbox: legacySandbox,
    }
  );

  assert.deepEqual(JSON.parse(capturedUpdateArgs[1]), expectedSandbox);
  assert.deepEqual(result.project.codexSandbox, expectedSandbox);
});

test("handleEpochProjectUpdate rejects invalid sandbox payloads instead of downgrading", async () => {
  let updateCalled = false;

  const repository = {
    async query(sql) {
      if (String(sql).includes("UPDATE projects")) {
        updateCalled = true;
      }
      throw new Error(`Unexpected SQL: ${String(sql)}`);
    },
  };

  await assert.rejects(
    () =>
      handleEpochProjectUpdate(
        {
          repository,
          engines: {},
        },
        {
          projectId: "123e4567-e89b-12d3-a456-426614174224",
          codexSandbox: { type: "not-a-real-mode" },
        }
      ),
    /Invalid codexSandbox/
  );

  assert.equal(updateCalled, false);
});
