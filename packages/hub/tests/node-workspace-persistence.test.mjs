import test from "node:test";
import assert from "node:assert/strict";

import { upsertNodeConnectionSnapshot } from "../dist/index.js";

test("upsertNodeConnectionSnapshot persists node workspace root and refreshes last_seen_at", async () => {
  const queries = [];
  const pool = {
    async query(sql, args = []) {
      queries.push({ sql: String(sql), args });
      return [];
    },
  };

  const nodeCtx = {
    role: "node",
    connectionId: "conn_node_1",
    deviceId: "node_device_1",
    deviceName: "Epoch HPC Bridge",
    platform: "darwin",
    clientName: "@epoch/hpc-bridge",
    clientVersion: "0.1.0",
    caps: ["slurm", "fs"],
    commands: ["shell.exec", "runtime.exec.start"],
    permissions: {
      workspaceRoot: "/tmp/epoch",
      defaults: { qos: "normal" },
    },
  };

  const connectedAt = "2026-02-27T03:50:00.000Z";
  const heartbeatAt = "2026-02-27T03:55:00.000Z";

  await upsertNodeConnectionSnapshot(pool, nodeCtx, connectedAt);
  await upsertNodeConnectionSnapshot(pool, nodeCtx, heartbeatAt);

  assert.equal(queries.length, 2);
  assert.match(queries[0].sql, /INSERT INTO nodes/);
  assert.match(queries[0].sql, /ON CONFLICT \(id\) DO UPDATE SET/);

  assert.equal(queries[0].args[0], "node_device_1");
  assert.equal(queries[0].args[1], "node_device_1");
  assert.equal(queries[0].args[8], connectedAt);
  assert.equal(queries[0].args[9], connectedAt);

  const persistedPermissions = JSON.parse(queries[0].args[7]);
  assert.equal(persistedPermissions.workspaceRoot, "/tmp/epoch");

  assert.equal(queries[1].args[8], heartbeatAt);
  assert.equal(queries[1].args[9], heartbeatAt);
});
