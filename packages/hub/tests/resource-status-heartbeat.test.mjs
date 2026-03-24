import test from "node:test";
import assert from "node:assert/strict";

import { mergeResourceSnapshotFromHeartbeat } from "../dist/index.js";

test("mergeResourceSnapshotFromHeartbeat keeps gpuPercent undefined when absent", () => {
  const baseline = {
    computeConnected: false,
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
    storageUsedPercent: 0,
    cpuPercent: 0,
    ramPercent: 0,
  };

  const next = mergeResourceSnapshotFromHeartbeat(baseline, {
    storageUsedPercent: 25.5,
    storageTotalBytes: 1_000,
    storageUsedBytes: 255,
    storageAvailableBytes: 745,
    cpuPercent: 42,
    ramPercent: 66,
    gpuPercent: 88,
  });

  assert.equal(next.computeConnected, true);
  assert.equal(next.gpuPercent, 88);
  assert.equal(next.storageAvailableBytes, 745);
  assert.equal(Object.prototype.hasOwnProperty.call(next, "queueDepth"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(next, "hpc"), false);
});

test("mergeResourceSnapshotFromHeartbeat ignores malformed expanded fields", () => {
  const baseline = {
    computeConnected: true,
    storageUsedPercent: 10,
    cpuPercent: 20,
    ramPercent: 30,
    gpuPercent: 40,
  };

  const next = mergeResourceSnapshotFromHeartbeat(baseline, {
    gpuPercent: "bad",
  });

  assert.equal(next.gpuPercent, 40);
  assert.equal(Object.prototype.hasOwnProperty.call(next, "queueDepth"), false);
  assert.equal(Object.prototype.hasOwnProperty.call(next, "hpc"), false);
});
