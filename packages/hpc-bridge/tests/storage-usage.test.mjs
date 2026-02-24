import test from "node:test";
import assert from "node:assert/strict";

import { parseDfPkOutput } from "../dist/index.js";

test("parseDfPkOutput extracts total used and available bytes", () => {
  const raw = `
Filesystem 1024-blocks    Used Available Capacity Mounted on
/dev/sda1      2000000 500000   1500000      25% /
`;

  const usage = parseDfPkOutput(raw);
  assert.ok(usage);
  assert.equal(usage.totalBytes, 2_000_000 * 1024);
  assert.equal(usage.usedBytes, 500_000 * 1024);
  assert.equal(usage.availableBytes, 1_500_000 * 1024);
  assert.equal(usage.usedPercent, 25);
});

test("parseDfPkOutput returns null for malformed output", () => {
  const usage = parseDfPkOutput("not df output");
  assert.equal(usage, null);
});
