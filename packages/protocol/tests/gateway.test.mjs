import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

test("exports a stable gateway.json", async () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const gatewayPath = path.join(here, "..", "dist", "gateway.json");

  const raw = await readFile(gatewayPath, "utf8");
  const parsed = JSON.parse(raw);

  assert.equal(parsed.version, 1);
  assert.ok(Array.isArray(parsed.operatorMethods));
  assert.ok(Array.isArray(parsed.nodeMethods));
  assert.ok(Array.isArray(parsed.eventNames));
  assert.ok(Array.isArray(parsed.errorCodes));
  assert.ok(parsed.operatorMethods.includes("projects.list"));
  assert.ok(parsed.operatorMethods.includes("projects.update"));
  assert.ok(parsed.nodeMethods.includes("slurm.submit"));
  assert.ok(parsed.eventNames.includes("connect.challenge"));
  assert.ok(parsed.errorCodes.includes("INTERNAL"));
});
