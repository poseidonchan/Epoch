import { constants as fsConstants } from "node:fs";
import { access, open, readdir, realpath, stat } from "node:fs/promises";
import path from "node:path";

import type { CodexRepository } from "./codex_rpc/repository.js";

export type ResolvedWorkspaceDirectory = {
  path: string;
  name: string;
  parentPath: string | null;
};

export type WorkspaceDirectoryEntry = {
  name: string;
  path: string;
};

export type BoundProjectWorkspaceEntry = {
  path: string;
  type: "file" | "dir";
  sizeBytes?: number;
  modifiedAt?: string;
};

export type ListWorkspaceDirectoriesOptions = {
  includeHidden?: boolean;
  limit?: number;
};

export type ListBoundProjectWorkspaceOptions = {
  path?: string;
  recursive?: boolean;
  includeHidden?: boolean;
  limit?: number;
};

export type ReadBoundProjectWorkspaceFileOptions = {
  encoding: "utf8" | "base64";
  maxBytes?: number;
  offset?: number;
  length?: number;
};

type ProjectWorkspaceRepository = Pick<CodexRepository, "query">;

export async function resolveWorkspaceDirectory(rawPath: string): Promise<ResolvedWorkspaceDirectory> {
  const normalizedPath = normalizeAbsolutePath(rawPath);
  if (!normalizedPath) {
    throw new Error("workspacePath must be a non-empty absolute path");
  }

  const resolvedPath = await realpath(normalizedPath).catch((error: unknown) => {
    throw new Error(`Workspace directory is unavailable: ${formatErrorMessage(error)}`);
  });
  const info = await stat(resolvedPath).catch((error: unknown) => {
    throw new Error(`Workspace directory is unavailable: ${formatErrorMessage(error)}`);
  });
  if (!info.isDirectory()) {
    throw new Error("workspacePath must point to an existing directory");
  }

  const parentPath = path.dirname(resolvedPath);
  return {
    path: resolvedPath,
    name: path.basename(resolvedPath),
    parentPath: parentPath === resolvedPath ? null : parentPath,
  };
}

export async function requireWritableWorkspaceDirectory(rawPath: string): Promise<ResolvedWorkspaceDirectory> {
  const resolved = await resolveWorkspaceDirectory(rawPath);
  try {
    await access(resolved.path, fsConstants.R_OK | fsConstants.W_OK);
  } catch (error) {
    throw new Error(`workspacePath must be readable and writable: ${formatErrorMessage(error)}`);
  }
  return resolved;
}

export async function listWorkspaceDirectories(
  rawPath: string,
  opts: ListWorkspaceDirectoriesOptions = {}
): Promise<{ path: string; entries: WorkspaceDirectoryEntry[]; truncated: boolean }> {
  const resolved = await resolveWorkspaceDirectory(rawPath);
  const includeHidden = opts.includeHidden === true;
  const limit = clampDirectoryLimit(opts.limit);
  const children = await readdir(resolved.path, { withFileTypes: true });
  const entries: WorkspaceDirectoryEntry[] = [];

  for (const child of children) {
    if (!includeHidden && child.name.startsWith(".")) {
      continue;
    }

    const childPath = path.join(resolved.path, child.name);
    const isDirectory = child.isDirectory() || (child.isSymbolicLink() && (await stat(childPath).catch(() => null))?.isDirectory() === true);
    if (!isDirectory) {
      continue;
    }

    entries.push({
      name: child.name,
      path: childPath,
    });
  }

  entries.sort((left, right) => left.name.localeCompare(right.name));
  return {
    path: resolved.path,
    entries: entries.slice(0, limit),
    truncated: entries.length > limit,
  };
}

export async function assertWorkspacePathIsUnbound(
  repository: ProjectWorkspaceRepository,
  workspacePath: string,
  excludeProjectId?: string | null
): Promise<void> {
  const rows = excludeProjectId
    ? await repository.query<{ id: string }>(
        `SELECT id FROM projects
         WHERE hpc_workspace_path=$1 AND id <> $2
         LIMIT 1`,
        [workspacePath, excludeProjectId]
      )
    : await repository.query<{ id: string }>(
        `SELECT id FROM projects
         WHERE hpc_workspace_path=$1
         LIMIT 1`,
        [workspacePath]
      );

  if ((rows[0]?.id ?? "").trim()) {
    throw new Error("workspacePath is already bound to an existing project");
  }
}

export async function resolveBoundProjectWorkspacePath(
  repository: ProjectWorkspaceRepository,
  projectId: string | null
): Promise<string | null> {
  if (!projectId) {
    return null;
  }

  const rows = await repository.query<any>(
    `SELECT id, hpc_workspace_path, hpc_workspace_state
     FROM projects
     WHERE id=$1
     LIMIT 1`,
    [projectId]
  );
  const project = rows[0] ?? null;
  if (!project) {
    throw new Error("Project not found");
  }

  const workspacePath = normalizeAbsolutePath(project.hpc_workspace_path);
  if (!workspacePath) {
    throw new Error("Project workspace path is not configured.");
  }
  if (normalizeString(project.hpc_workspace_state) === "unavailable") {
    throw new Error("Project workspace path is unavailable.");
  }

  try {
    const resolved = await resolveWorkspaceDirectory(workspacePath);
    return resolved.path;
  } catch (error) {
    throw new Error(`Project workspace path is unavailable: ${formatErrorMessage(error)}`);
  }
}

export async function listBoundProjectWorkspaceEntries(
  repository: ProjectWorkspaceRepository,
  projectId: string | null,
  opts: ListBoundProjectWorkspaceOptions = {}
): Promise<{ path: string; entries: BoundProjectWorkspaceEntry[]; truncated: boolean }> {
  const workspaceRoot = await resolveBoundProjectWorkspacePath(repository, projectId);
  if (!workspaceRoot) {
    throw new Error("Project workspace path is not configured.");
  }

  const requestedPath = normalizeBoundWorkspacePath(opts.path ?? ".") ?? ".";
  const startPath = resolvePathWithinWorkspace(workspaceRoot, requestedPath);
  const startInfo = await stat(startPath).catch((error: unknown) => {
    throw new Error(`Project workspace path is unavailable: ${formatErrorMessage(error)}`);
  });

  const recursive = opts.recursive !== false;
  const includeHidden = opts.includeHidden === true;
  const limit = clampBoundWorkspaceLimit(opts.limit, 3_000, 20_000);
  const entries: BoundProjectWorkspaceEntry[] = [];
  let truncated = false;

  if (startInfo.isFile()) {
    const single = toBoundProjectWorkspaceEntry(workspaceRoot, startPath, startInfo);
    if (single && (includeHidden || !hasHiddenPathSegment(single.path))) {
      entries.push(single);
    }
    return { path: requestedPath, entries, truncated: false };
  }
  if (!startInfo.isDirectory()) {
    throw new Error("Project workspace path must point to a directory");
  }

  const visit = async (dirPath: string): Promise<boolean> => {
    const children = await readdir(dirPath, { withFileTypes: true });
    children.sort((left, right) => left.name.localeCompare(right.name));

    for (const child of children) {
      if (!includeHidden && child.name.startsWith(".")) {
        continue;
      }

      const childPath = path.join(dirPath, child.name);
      const childInfo = await stat(childPath).catch(() => null);
      if (!childInfo) {
        continue;
      }

      const entry = toBoundProjectWorkspaceEntry(workspaceRoot, childPath, childInfo);
      if (!entry) {
        continue;
      }

      entries.push(entry);
      if (entries.length >= limit) {
        truncated = true;
        return false;
      }

      if (recursive && childInfo.isDirectory()) {
        const shouldContinue = await visit(childPath);
        if (!shouldContinue) {
          return false;
        }
      }
    }

    return true;
  };

  await visit(startPath);
  return {
    path: requestedPath,
    entries: entries.sort((left, right) => left.path.localeCompare(right.path)),
    truncated,
  };
}

export async function readBoundProjectWorkspaceFile(
  repository: ProjectWorkspaceRepository,
  projectId: string | null,
  relativePath: string,
  opts: ReadBoundProjectWorkspaceFileOptions
): Promise<{ path: string; data: string; eof: boolean; sizeBytes: number }> {
  const workspaceRoot = await resolveBoundProjectWorkspacePath(repository, projectId);
  if (!workspaceRoot) {
    throw new Error("Project workspace path is not configured.");
  }

  const normalizedPath = normalizeBoundWorkspacePath(relativePath);
  if (!normalizedPath || normalizedPath === ".") {
    throw new Error("workspace path must be a non-empty relative file path");
  }

  const absolutePath = resolvePathWithinWorkspace(workspaceRoot, normalizedPath);
  const info = await stat(absolutePath).catch((error: unknown) => {
    throw new Error(`Project workspace path is unavailable: ${formatErrorMessage(error)}`);
  });
  if (!info.isFile()) {
    throw new Error("workspace path must point to a file");
  }

  const offset = normalizeReadOffset(opts.offset);
  const remaining = Math.max(0, info.size - offset);
  const length = normalizeReadLength(opts.length, remaining);
  const maxBytes = Number.isFinite(opts.maxBytes) ? Math.max(1, Math.floor(opts.maxBytes ?? 0)) : null;
  const bytesToRead = Math.min(remaining, length);
  if (maxBytes != null && bytesToRead > maxBytes) {
    throw new Error(`workspace preview exceeds max preview size (${formatByteLimit(maxBytes)})`);
  }

  const handle = await open(absolutePath, "r");
  const buffer = Buffer.alloc(bytesToRead);
  let bytesRead = 0;
  try {
    while (bytesRead < bytesToRead) {
      const chunk = await handle.read(buffer, bytesRead, bytesToRead - bytesRead, offset + bytesRead);
      if (chunk.bytesRead <= 0) {
        break;
      }
      bytesRead += chunk.bytesRead;
    }
  } finally {
    await handle.close();
  }
  const slice = buffer.subarray(0, bytesRead);

  return {
    path: normalizedPath,
    data: opts.encoding === "base64" ? slice.toString("base64") : slice.toString("utf8"),
    eof: offset + slice.length >= info.size,
    sizeBytes: info.size,
  };
}

function clampDirectoryLimit(rawLimit: number | undefined): number {
  if (!Number.isFinite(rawLimit)) {
    return 200;
  }
  return Math.max(1, Math.min(500, Math.floor(rawLimit ?? 200)));
}

function clampBoundWorkspaceLimit(rawLimit: number | undefined, fallback: number, max: number): number {
  if (!Number.isFinite(rawLimit)) {
    return fallback;
  }
  return Math.max(1, Math.min(max, Math.floor(rawLimit ?? fallback)));
}

function normalizeAbsolutePath(rawPath: unknown): string | null {
  if (typeof rawPath !== "string") {
    return null;
  }
  const value = rawPath.trim();
  if (!value || !path.isAbsolute(value)) {
    return null;
  }
  return value;
}

function normalizeBoundWorkspacePath(rawPath: unknown): string | null {
  if (typeof rawPath !== "string") {
    return null;
  }
  const trimmed = rawPath.trim();
  if (!trimmed) {
    return null;
  }
  const normalized = path.posix.normalize(trimmed.replaceAll("\\", "/"));
  if (normalized === ".." || normalized.startsWith("../") || normalized.startsWith("/")) {
    return null;
  }
  return normalized === "" ? "." : normalized;
}

function normalizeString(raw: unknown): string | null {
  if (typeof raw !== "string") {
    return null;
  }
  const value = raw.trim().toLowerCase();
  return value || null;
}

function formatErrorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error ?? "unknown error");
}

function resolvePathWithinWorkspace(workspaceRoot: string, relativePath: string): string {
  const absolutePath = path.resolve(workspaceRoot, relativePath);
  const relativeFromRoot = path.relative(workspaceRoot, absolutePath);
  if (relativeFromRoot === ".." || relativeFromRoot.startsWith(`..${path.sep}`) || path.isAbsolute(relativeFromRoot)) {
    throw new Error("workspace path escapes the bound directory");
  }
  return absolutePath;
}

function toBoundProjectWorkspaceEntry(
  workspaceRoot: string,
  absolutePath: string,
  info: Awaited<ReturnType<typeof stat>>
): BoundProjectWorkspaceEntry | null {
  const relativePath = path.relative(workspaceRoot, absolutePath);
  if (!relativePath || relativePath.startsWith(`..${path.sep}`) || path.isAbsolute(relativePath)) {
    return null;
  }

  const normalizedPath = relativePath.split(path.sep).join("/");
  if (info.isDirectory()) {
    return {
      path: normalizedPath,
      type: "dir",
      modifiedAt: info.mtime.toISOString(),
    };
  }
  if (info.isFile()) {
    return {
      path: normalizedPath,
      type: "file",
      sizeBytes: info.size,
      modifiedAt: info.mtime.toISOString(),
    };
  }
  return null;
}

function hasHiddenPathSegment(relativePath: string): boolean {
  return relativePath.split("/").some((segment) => segment.startsWith("."));
}

function normalizeReadOffset(rawOffset: number | undefined): number {
  if (!Number.isFinite(rawOffset)) {
    return 0;
  }
  return Math.max(0, Math.floor(rawOffset ?? 0));
}

function normalizeReadLength(rawLength: number | undefined, fallback: number): number {
  if (!Number.isFinite(rawLength)) {
    return Math.max(0, fallback);
  }
  return Math.max(0, Math.floor(rawLength ?? fallback));
}

function formatByteLimit(bytes: number): string {
  if (bytes >= 1024 * 1024) {
    return `${Math.round(bytes / (1024 * 1024))} MB`;
  }
  if (bytes >= 1024) {
    return `${Math.round(bytes / 1024)} KB`;
  }
  return `${bytes} B`;
}
