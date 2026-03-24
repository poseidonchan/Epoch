import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, writeFile, realpath } from "node:fs/promises";

import { operatorMethods } from "@epoch/protocol";
import { listWorkspaceDirectories, resolveWorkspaceDirectory } from "../dist/index.js";

test("operator methods expose workspace directory browsing endpoints", () => {
  assert.equal(operatorMethods.includes("workspace.directories.list"), true);
  assert.equal(operatorMethods.includes("workspace.directories.resolve"), true);
});

test("workspace directory helpers resolve and list existing directories", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "epoch-workspace-directories-"));
  const visibleChild = path.join(root, "alpha");
  const hiddenChild = path.join(root, ".hidden");
  const regularFile = path.join(root, "notes.txt");

  await mkdir(visibleChild, { recursive: true });
  await mkdir(hiddenChild, { recursive: true });
  await writeFile(regularFile, "ignore me", "utf8");

  const resolvedRoot = await realpath(root);
  const resolvedVisibleChild = await realpath(visibleChild);

  const resolved = await resolveWorkspaceDirectory(root);
  assert.equal(resolved.path, resolvedRoot);
  assert.equal(resolved.name, path.basename(resolvedRoot));
  assert.equal(resolved.parentPath, path.dirname(resolvedRoot));

  const listed = await listWorkspaceDirectories(root, { includeHidden: false, limit: 10 });
  assert.equal(listed.path, resolvedRoot);
  assert.deepEqual(listed.entries, [
    {
      name: path.basename(resolvedVisibleChild),
      path: resolvedVisibleChild,
    },
  ]);
  assert.equal(listed.truncated, false);

  const hiddenListed = await listWorkspaceDirectories(root, { includeHidden: true, limit: 1 });
  assert.equal(hiddenListed.entries.length, 1);
  assert.equal(hiddenListed.truncated, true);
});
