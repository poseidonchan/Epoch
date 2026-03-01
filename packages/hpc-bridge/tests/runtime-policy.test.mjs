import test from "node:test";
import assert from "node:assert/strict";

import {
  resolveRuntimePolicyOverride,
  isRuntimeExecConcurrencyExceeded,
  isSlurmConcurrencyExceeded,
} from "../dist/index.js";

test("resolveRuntimePolicyOverride keeps default-open behavior", () => {
  assert.equal(resolveRuntimePolicyOverride(undefined), null);
  assert.equal(resolveRuntimePolicyOverride(null), null);
});

test("runtime exec concurrency only applies when policy override provides a cap", () => {
  assert.equal(isRuntimeExecConcurrencyExceeded(50, null), false);
  assert.equal(isRuntimeExecConcurrencyExceeded(2, { exec: {} }), false);
  assert.equal(isRuntimeExecConcurrencyExceeded(1, { exec: { maxConcurrent: 2 } }), false);
  assert.equal(isRuntimeExecConcurrencyExceeded(2, { exec: { maxConcurrent: 2 } }), true);
});

test("slurm concurrency only applies when policy override provides a cap", () => {
  assert.equal(isSlurmConcurrencyExceeded(10, 10, null), false);
  assert.equal(isSlurmConcurrencyExceeded(1, 1, { slurm: {} }), false);
  assert.equal(isSlurmConcurrencyExceeded(1, 0, { slurm: { maxConcurrent: 2 } }), false);
  assert.equal(isSlurmConcurrencyExceeded(1, 1, { slurm: { maxConcurrent: 2 } }), true);
});
