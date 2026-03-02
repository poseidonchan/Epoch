import test from "node:test";
import assert from "node:assert/strict";

import { mergeResourceSnapshotFromHeartbeat } from "../dist/index.js";

test("mergeResourceSnapshotFromHeartbeat keeps gpuPercent undefined when absent", () => {
  const baseline = {
    computeConnected: false,
    queueDepth: 0,
    storageUsedPercent: 0,
    cpuPercent: 0,
    ramPercent: 0,
  };

  const next = mergeResourceSnapshotFromHeartbeat(baseline, {
    queueDepth: 1,
    cpuPercent: 10,
    ramPercent: 20,
  });

  assert.equal(Object.prototype.hasOwnProperty.call(next, "gpuPercent"), false);
  assert.equal(next.gpuPercent, undefined);
});

test("mergeResourceSnapshotFromHeartbeat applies expanded heartbeat fields", () => {
  const baseline = {
    computeConnected: false,
    queueDepth: 0,
    storageUsedPercent: 0,
    cpuPercent: 0,
    ramPercent: 0,
  };

  const next = mergeResourceSnapshotFromHeartbeat(baseline, {
    queueDepth: 3,
    storageUsedPercent: 25.5,
    storageTotalBytes: 1_000,
    storageUsedBytes: 255,
    storageAvailableBytes: 745,
    cpuPercent: 42,
    ramPercent: 66,
    gpuPercent: 88,
    hpc: {
      partition: "gpu",
      runningJobs: 2,
      pendingJobs: 1,
      requestable: { cpu: 64, memMB: 128_000, gpus: 8 },
      supplyPool: {
        idleNodes: 1,
        mixedNodes: 2,
        totalNodes: 3,
        availableCpu: 96,
        availableMemMB: 384_000,
        availableGpus: 10,
        scope: "IDLE+MIXED",
        updatedAt: "2026-03-01T01:02:03.000Z",
      },
      nodes: [
        {
          nodeName: "login01",
          role: "login",
          source: "job",
          cpuPercent: 11,
          ramPercent: 33,
          updatedAt: "2026-03-01T01:02:03.000Z",
        },
      ],
      updatedAt: "2026-03-01T01:02:03.000Z",
    },
  });

  assert.equal(next.computeConnected, true);
  assert.equal(next.queueDepth, 3);
  assert.equal(next.gpuPercent, 88);
  assert.equal(next.hpc?.requestable?.cpu, 64);
  assert.equal(next.hpc?.supplyPool?.scope, "IDLE+MIXED");
  assert.equal(next.hpc?.nodes?.[0]?.nodeName, "login01");
});

test("mergeResourceSnapshotFromHeartbeat ignores malformed expanded fields", () => {
  const baseline = {
    computeConnected: true,
    queueDepth: 1,
    storageUsedPercent: 10,
    cpuPercent: 20,
    ramPercent: 30,
    gpuPercent: 40,
    hpc: {
      runningJobs: 1,
      pendingJobs: 0,
      updatedAt: "2026-03-01T00:00:00.000Z",
      supplyPool: {
        idleNodes: 0,
        mixedNodes: 1,
        totalNodes: 1,
        scope: "IDLE+MIXED",
        updatedAt: "2026-03-01T00:00:00.000Z",
      },
    },
  };

  const next = mergeResourceSnapshotFromHeartbeat(baseline, {
    queueDepth: "bad",
    gpuPercent: "bad",
    hpc: {
      runningJobs: "bad",
      supplyPool: { idleNodes: "bad", scope: 123 },
      nodes: [{ nodeName: 123 }],
      updatedAt: "bad",
    },
  });

  assert.equal(next.queueDepth, 1);
  assert.equal(next.gpuPercent, 40);
  assert.equal(next.hpc?.runningJobs, 0);
  assert.equal(next.hpc?.supplyPool, undefined);
  assert.equal(next.hpc?.nodes?.length ?? 0, 0);
});
