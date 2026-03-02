import test from "node:test";
import assert from "node:assert/strict";

import {
  parseProcStatSample,
  sampleCpuFromOsCpus,
  computeCpuPercentFromSamples,
  computeRamPercentFromTotals,
  parseMemInfoUsagePercent,
  parseNvidiaSmiUtilizationPercent,
  parseSinfoNodeStates,
  parseScontrolNodeAvailability,
  summarizeSupplyPool,
} from "../dist/index.js";

test("parseProcStatSample extracts cpu sample totals from /proc/stat", () => {
  const sample = parseProcStatSample("cpu  100 20 30 400 50 6 7 8 0 0\ncpu0 1 2 3 4\n");
  assert.ok(sample);
  assert.equal(sample.idle, 450);
  assert.equal(sample.total, 621);
});

test("computeCpuPercentFromSamples computes bounded cpu utilization", () => {
  const prev = { idle: 1_000, total: 2_000 };
  const next = { idle: 1_400, total: 2_900 };
  const percent = computeCpuPercentFromSamples(prev, next);
  assert.equal(percent, 55.56);
});

test("sampleCpuFromOsCpus aggregates cpu times into idle and total samples", () => {
  const sample = sampleCpuFromOsCpus([
    { times: { user: 100, nice: 5, sys: 50, idle: 845, irq: 0 } },
    { times: { user: 120, nice: 0, sys: 80, idle: 800, irq: 0 } },
  ]);
  assert.deepEqual(sample, {
    idle: 1_645,
    total: 2_000,
  });
});

test("sampleCpuFromOsCpus output works with computeCpuPercentFromSamples", () => {
  const prev = sampleCpuFromOsCpus([
    { times: { user: 100, nice: 5, sys: 50, idle: 845, irq: 0 } },
    { times: { user: 120, nice: 0, sys: 80, idle: 800, irq: 0 } },
  ]);
  const next = sampleCpuFromOsCpus([
    { times: { user: 120, nice: 5, sys: 60, idle: 855, irq: 0 } },
    { times: { user: 125, nice: 0, sys: 95, idle: 820, irq: 0 } },
  ]);
  const percent = computeCpuPercentFromSamples(prev, next);
  assert.equal(percent, 62.5);
});

test("parseMemInfoUsagePercent computes memory utilization from MemTotal/MemAvailable", () => {
  const raw = `
MemTotal:       16000000 kB
MemFree:         1000000 kB
MemAvailable:    4000000 kB
`;
  const usage = parseMemInfoUsagePercent(raw);
  assert.equal(usage, 75);
});

test("computeRamPercentFromTotals computes bounded memory utilization", () => {
  assert.equal(computeRamPercentFromTotals(16_000, 4_000), 75);
  assert.equal(computeRamPercentFromTotals(100, 120), 0);
  assert.equal(computeRamPercentFromTotals(100, -20), 100);
  assert.equal(computeRamPercentFromTotals(0, 0), null);
});

test("parseNvidiaSmiUtilizationPercent averages gpu utilization values", () => {
  const raw = "10\n70\n90\n";
  const usage = parseNvidiaSmiUtilizationPercent(raw);
  assert.equal(usage, 56.67);
});

test("parseSinfoNodeStates parses idle and mixed nodes", () => {
  const rows = parseSinfoNodeStates("gpu001|idle\ngpu002|mix\ngpu003|mixed\n");
  assert.deepEqual(rows, [
    { nodeName: "gpu001", state: "IDLE" },
    { nodeName: "gpu002", state: "MIXED" },
    { nodeName: "gpu003", state: "MIXED" },
  ]);
});

test("parseScontrolNodeAvailability parses node allocation and gpu usage", () => {
  const row = parseScontrolNodeAvailability(
    "NodeName=gpu001 CPUAlloc=16 CPUTot=64 AllocMem=64000 RealMemory=256000 Gres=gpu:a100:4 GresUsed=gpu:a100:1"
  );
  assert.ok(row);
  assert.equal(row.nodeName, "gpu001");
  assert.equal(row.cpuAlloc, 16);
  assert.equal(row.cpuTotal, 64);
  assert.equal(row.allocMemMB, 64_000);
  assert.equal(row.realMemMB, 256_000);
  assert.equal(row.gpuUsed, 1);
  assert.equal(row.gpuTotal, 4);
});

test("summarizeSupplyPool aggregates IDLE+MIXED available resources", () => {
  const pool = summarizeSupplyPool({
    updatedAt: "2026-03-01T00:00:00.000Z",
    states: [
      { nodeName: "gpu001", state: "IDLE" },
      { nodeName: "gpu002", state: "MIXED" },
    ],
    availabilityByNode: new Map([
      [
        "gpu001",
        {
          nodeName: "gpu001",
          cpuAlloc: 0,
          cpuTotal: 64,
          allocMemMB: 0,
          realMemMB: 256_000,
          gpuUsed: 0,
          gpuTotal: 4,
        },
      ],
      [
        "gpu002",
        {
          nodeName: "gpu002",
          cpuAlloc: 48,
          cpuTotal: 64,
          allocMemMB: 192_000,
          realMemMB: 256_000,
          gpuUsed: 3,
          gpuTotal: 4,
        },
      ],
    ]),
  });

  assert.ok(pool);
  assert.equal(pool.scope, "IDLE+MIXED");
  assert.equal(pool.idleNodes, 1);
  assert.equal(pool.mixedNodes, 1);
  assert.equal(pool.totalNodes, 2);
  assert.equal(pool.availableCpu, 80);
  assert.equal(pool.availableMemMB, 320_000);
  assert.equal(pool.availableGpus, 5);
});
