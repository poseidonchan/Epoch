import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, writeFile, realpath } from "node:fs/promises";

import { operatorMethods } from "@epoch/protocol";
import {
  listBoundProjectWorkspaceEntries,
  listWorkspaceDirectories,
  resolveBoundProjectWorkspacePath,
  resolveWorkspaceDirectory,
} from "../dist/index.js";

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

test("workspace directory helpers expand tilde-rooted paths", async () => {
  const resolvedHome = await realpath(os.homedir());

  const resolved = await resolveWorkspaceDirectory("~");

  assert.equal(resolved.path, resolvedHome);
  assert.equal(resolved.name, path.basename(resolvedHome));
});

test("bound project workspace helpers repair legacy embedded-tilde persisted paths", async () => {
  const resolvedHome = await realpath(os.homedir());
  const repository = {
    async query(sql, args = []) {
      const normalized = String(sql);
      if (normalized.includes("FROM projects") && normalized.includes("hpc_workspace_path")) {
        assert.equal(args[0], "proj_legacy_tilde");
        return [
          {
            id: "proj_legacy_tilde",
            hpc_workspace_path: `${process.cwd()}/~`,
            hpc_workspace_state: "ready",
          },
        ];
      }
      throw new Error(`Unexpected SQL: ${normalized}`);
    },
  };

  const resolved = await resolveBoundProjectWorkspacePath(repository, "proj_legacy_tilde");
  assert.equal(resolved, resolvedHome);

  const listed = await listBoundProjectWorkspaceEntries(repository, "proj_legacy_tilde", { limit: 1 });
  assert.equal(listed.path, ".");
  assert.ok(Array.isArray(listed.entries));
});
