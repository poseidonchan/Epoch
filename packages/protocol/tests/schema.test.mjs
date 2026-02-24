import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

test("exports a stable schema.json", async () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const schemaPath = path.join(here, "..", "dist", "schema.json");

  const raw = await readFile(schemaPath, "utf8");
  const parsed = JSON.parse(raw);

  assert.equal(parsed.type, "object");
  assert.equal(parsed.properties?.version?.const, 1);
  assert.equal(parsed.properties?.types?.type, "object");
  assert.ok(parsed.properties?.types?.properties?.Project);
  assert.ok(parsed.properties?.types?.properties?.ChatMessage);
  assert.ok(parsed.properties?.types?.properties?.JobSpec);
});
