import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const packageJsonPath = path.resolve(__dirname, "../package.json");

test("hpc bridge package does not expose a public CLI", async () => {
  const raw = await readFile(packageJsonPath, "utf8");
  const pkg = JSON.parse(raw);

  assert.equal("bin" in pkg, false);
  assert.equal(pkg.private, true);
});
