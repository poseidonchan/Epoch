import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import process from "node:process";

import type { NodeMethod } from "@epoch/protocol";
import {
  buildWorkspaceWriteEnv,
  collectStorageUsage,
  computeCpuPercentFromSamples,
  computeRamPercentFromTotals,
  parseMemInfoUsagePercent,
  parseNvidiaSmiUtilizationPercent,
  parseProcStatSample,
  resolveRuntimeCommandCwd,
  sampleCpuFromOsCpus,
} from "@epoch/hpc-bridge";

const execFileAsync = promisify(execFile);

type PermissionLevel = "default" | "full";
type RuntimeSandboxMode = "workspace-write" | "danger-full-access" | "read-only";
type ProcCpuSample = { idle: number; total: number };
type RuntimeEventListener = (event: string, payload: Record<string, unknown>) => void;

export type LocalResourceSnapshot = {
  computeConnected: boolean;
  storageUsedPercent: number;
  storageTotalBytes?: number;
  storageUsedBytes?: number;
  storageAvailableBytes?: number;
  cpuPercent: number;
  ramPercent: number;
  gpuPercent?: number;
};

const LOCAL_RUNTIME_COMMANDS: NodeMethod[] = [
  "fs.list",
  "fs.readRange",
  "shell.exec",
  "runtime.exec.start",
  "runtime.exec.cancel",
  "runtime.fs.stat",
  "runtime.fs.read",
  "runtime.fs.write",
  "runtime.fs.list",
  "runtime.fs.diff",
  "runtime.fs.applyPatch",
  "artifact.scan",
  "logs.tail",
  "workspace.project.ensure",
];

const DANGEROUS_COMMANDS = new Set([
  "chown",
  "mkfs",
  "mkfs.ext4",
  "mkfs.xfs",
  "dd",
  "mount",
  "umount",
  "fdisk",
  "parted",
  "shutdown",
  "reboot",
  "poweroff",
  "useradd",
  "userdel",
  "passwd",
  "sudo",
  "su",
]);

const DEFAULT_ALLOWED_BINARIES = new Set([
  "bash",
  "sh",
  "zsh",
  "python",
  "python3",
  "pip",
  "pip3",
  "uv",
  "conda",
  "node",
  "npm",
  "pnpm",
  "git",
  "ls",
  "cat",
  "pwd",
  "echo",
  "mkdir",
  "cp",
  "mv",
  "rm",
  "touch",
  "find",
  "rg",
  "sed",
  "awk",
  "head",
  "tail",
  "wc",
]);

const SHELL_BINARIES = new Set(["bash", "sh", "zsh", "fish"]);

export class LocalRuntimeBridge {
  private readonly listeners = new Set<RuntimeEventListener>();
  private readonly activeExec = new Map<string, { child: ReturnType<typeof spawn>; startedAtMs: number; timedOut: boolean }>();
  private readonly projectPaths = new Map<string, string>();
  private prevCpuSample: ProcCpuSample | null = null;

  public constructor(private readonly opts: { stateDir: string; workspaceRoot: string }) {}

  public listNodeCommands(): string[] {
    return [...LOCAL_RUNTIME_COMMANDS];
  }

  public workspaceRoot(): string {
    return this.opts.workspaceRoot;
  }

  public subscribeNodeEvents(listener: RuntimeEventListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  public async resourceSnapshot(): Promise<LocalResourceSnapshot> {
    const [storage, cpuPercent, ramPercent, gpuPercent] = await Promise.all([
      collectStorageUsage(this.opts.workspaceRoot).catch(() => null),
      this.readCpuPercent().catch(() => 0),
      this.readRamPercent().catch(() => 0),
      this.readGpuPercent().catch(() => undefined),
    ]);

    return {
      computeConnected: true,
      storageUsedPercent: storage?.usedPercent ?? 0,
      ...(storage?.totalBytes != null ? { storageTotalBytes: storage.totalBytes } : {}),
      ...(storage?.usedBytes != null ? { storageUsedBytes: storage.usedBytes } : {}),
      ...(storage?.availableBytes != null ? { storageAvailableBytes: storage.availableBytes } : {}),
      cpuPercent,
      ramPercent,
      ...(gpuPercent == null ? {} : { gpuPercent }),
    };
  }

  public async callNode(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    switch (method as NodeMethod) {
      case "workspace.project.ensure":
        return await this.workspaceProjectEnsure(
          String(params.projectId ?? ""),
          normalizeOptionalString(params.workspacePath)
        );
      case "runtime.exec.start":
        return await this.runtimeExecStart({
          projectId: String(params.projectId ?? "").trim(),
          workspacePath: normalizeOptionalString(params.workspacePath),
          sessionId: String(params.sessionId ?? "").trim(),
          threadId: String(params.threadId ?? "").trim(),
          turnId: String(params.turnId ?? "").trim(),
          itemId: String(params.itemId ?? "").trim(),
          executionId: String(params.executionId ?? "").trim(),
          command: Array.isArray(params.command) ? params.command.map(String).filter(Boolean) : [],
          cwd: params.cwd == null ? undefined : String(params.cwd),
          env: normalizeStringRecord(params.env),
          timeoutMs: normalizePositiveInteger(params.timeoutMs),
          permissionLevel: normalizePermissionLevel(params.permissionLevel) ?? "default",
          sandboxMode: normalizeSandboxMode(params.sandboxMode),
        });
      case "runtime.exec.cancel":
        return { ok: true, cancelled: await this.runtimeExecCancel(String(params.executionId ?? "").trim()) };
      case "runtime.fs.stat":
        return await this.runtimeFsStat(
          String(params.projectId ?? "").trim(),
          normalizeOptionalString(params.workspacePath),
          String(params.path ?? "")
        );
      case "runtime.fs.read":
        return await this.runtimeFsRead(
          String(params.projectId ?? "").trim(),
          normalizeOptionalString(params.workspacePath),
          String(params.path ?? ""),
          normalizeNonNegativeInteger(params.offset) ?? 0,
          normalizeNonNegativeInteger(params.length) ?? 64 * 1024,
          String(params.encoding ?? "utf8")
        );
      case "runtime.fs.write":
        return await this.runtimeFsWrite(
          String(params.projectId ?? "").trim(),
          normalizeOptionalString(params.workspacePath),
          String(params.path ?? ""),
          String(params.data ?? ""),
          String(params.encoding ?? "utf8"),
          normalizePermissionLevel(params.permissionLevel) ?? "default"
        );
      case "runtime.fs.list":
        return await this.runtimeFsList(
          String(params.projectId ?? "").trim(),
          normalizeOptionalString(params.workspacePath),
          String(params.path ?? "."),
          {
          recursive: params.recursive == null ? true : Boolean(params.recursive),
          includeHidden: Boolean(params.includeHidden ?? false),
          limit: normalizePositiveInteger(params.limit) ?? 3_000,
          }
        );
      case "runtime.fs.diff":
        return await this.runtimeFsDiff(
          String(params.projectId ?? "").trim(),
          normalizeOptionalString(params.workspacePath),
          Array.isArray(params.paths) ? params.paths.map(String).filter(Boolean) : []
        );
      case "runtime.fs.applyPatch":
        return await this.runtimeFsApplyPatch({
          projectId: String(params.projectId ?? "").trim(),
          workspacePath: normalizeOptionalString(params.workspacePath),
          sessionId: String(params.sessionId ?? "").trim(),
          threadId: String(params.threadId ?? "").trim(),
          turnId: String(params.turnId ?? "").trim(),
          itemId: String(params.itemId ?? "").trim(),
          patchId: String(params.patchId ?? "patch").trim(),
          patch: normalizeOptionalString(params.patch) ?? normalizeOptionalString(params.unifiedDiff) ?? normalizeOptionalString(params.unified_diff),
          fileChanges: params.fileChanges && typeof params.fileChanges === "object" && !Array.isArray(params.fileChanges)
            ? (params.fileChanges as Record<string, unknown>)
            : undefined,
          permissionLevel: normalizePermissionLevel(params.permissionLevel) ?? "default",
        });
      case "shell.exec":
        return await this.shellExec({
          projectId: String(params.projectId ?? "").trim(),
          workspacePath: normalizeOptionalString(params.workspacePath),
          runId: String(params.runId ?? "").trim(),
          command: Array.isArray(params.command) ? params.command.map(String).filter(Boolean) : [],
          cwd: params.cwd == null ? undefined : String(params.cwd),
          env: normalizeStringRecord(params.env),
          timeoutMs: normalizePositiveInteger(params.timeoutMs),
          permissionLevel: normalizePermissionLevel(params.permissionLevel) ?? "default",
        });
      case "artifact.scan":
        return {
          artifacts: await this.scanArtifacts(
            String(params.projectId ?? "").trim(),
            normalizeOptionalString(params.workspacePath),
            String(params.root ?? "artifacts")
          ),
        };
      case "logs.tail":
        return await this.logsTail(String(params.path ?? ""), normalizeNonNegativeInteger(params.sinceOffset) ?? 0);
      case "fs.list":
        return { entries: await this.fsList(String(params.path ?? this.opts.workspaceRoot)) };
      case "fs.readRange":
        return await this.fsReadRange(
          String(params.path ?? ""),
          normalizeNonNegativeInteger(params.offset) ?? 0,
          normalizeNonNegativeInteger(params.length) ?? 64 * 1024,
          String(params.encoding ?? "utf8")
        );
      default:
        throw new Error(`Unsupported local runtime method: ${method}`);
    }
  }

  private emit(event: string, payload: Record<string, unknown>) {
    for (const listener of this.listeners) {
      listener(event, payload);
    }
  }

  private async workspaceProjectEnsure(projectId: string, workspacePath?: string) {
    if (!projectId) {
      throw new Error("Missing projectId");
    }
    const projectRoot = this.projectRoot(projectId, workspacePath);
    this.projectPaths.set(projectId, projectRoot);
    await this.ensureProjectWorkspaceDirs(projectRoot);
    return {
      ok: true,
      projectId,
      workspacePath: projectRoot,
      updatedAt: new Date().toISOString(),
    };
  }

  private async runtimeExecStart(opts: {
    projectId: string;
    workspacePath?: string;
    sessionId: string;
    threadId: string;
    turnId: string;
    itemId: string;
    executionId: string;
    command: string[];
    cwd?: string;
    env?: Record<string, string>;
    timeoutMs?: number;
    permissionLevel: PermissionLevel;
    sandboxMode: RuntimeSandboxMode;
  }) {
    if (!opts.projectId || !opts.sessionId || !opts.threadId || !opts.turnId || !opts.itemId || !opts.executionId || opts.command.length === 0) {
      throw new Error("runtime.exec.start requires project/session/thread/turn/item ids and command");
    }

    this.assertRuntimeCommandPolicy(opts.command, opts.permissionLevel);

    const projectRoot = path.resolve(this.projectRoot(opts.projectId, opts.workspacePath));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const resolvedCwd = resolveRuntimeCommandCwd({
      workspaceRoot: this.opts.workspaceRoot,
      projectRoot,
      rawCwd: opts.cwd,
      fallbackCwd: projectRoot,
    });
    const cwd = await this.resolveProjectPath(opts.projectId, opts.workspacePath, resolvedCwd, { forWrite: true });
    this.assertAllowedProjectPath(opts.projectId, opts.workspacePath, cwd);

    const startedAt = Date.now();
    this.emit("runtime.exec.started", {
      projectId: opts.projectId,
      sessionId: opts.sessionId,
      threadId: opts.threadId,
      turnId: opts.turnId,
      itemId: opts.itemId,
      executionId: opts.executionId,
      command: opts.command,
      cwd,
      permissionLevel: opts.permissionLevel,
      ts: new Date(startedAt).toISOString(),
    });

    let env: NodeJS.ProcessEnv = { ...process.env, ...(opts.env ?? {}) };
    if (opts.sandboxMode === "workspace-write") {
      env = { ...process.env, ...buildWorkspaceWriteEnv(projectRoot), ...(opts.env ?? {}) };
      await mkdir(path.join(projectRoot, "tmp"), { recursive: true });
    }

    const child = spawn(opts.command[0]!, opts.command.slice(1), {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const procState = { child, startedAtMs: startedAt, timedOut: false };
    this.activeExec.set(opts.executionId, procState);

    child.stdout?.on("data", (chunk: Buffer | string) => {
      const delta = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (!delta) return;
      stdout += delta;
      this.emit("runtime.exec.outputDelta", {
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        threadId: opts.threadId,
        turnId: opts.turnId,
        itemId: opts.itemId,
        executionId: opts.executionId,
        stream: "stdout",
        delta,
        ts: new Date().toISOString(),
      });
    });

    child.stderr?.on("data", (chunk: Buffer | string) => {
      const delta = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (!delta) return;
      stderr += delta;
      this.emit("runtime.exec.outputDelta", {
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        threadId: opts.threadId,
        turnId: opts.turnId,
        itemId: opts.itemId,
        executionId: opts.executionId,
        stream: "stderr",
        delta,
        ts: new Date().toISOString(),
      });
    });

    let timeoutId: NodeJS.Timeout | null = null;
    if (opts.timeoutMs && opts.timeoutMs > 0) {
      timeoutId = setTimeout(() => {
        procState.timedOut = true;
        try {
          child.kill("SIGTERM");
        } catch {
          // ignore
        }
      }, opts.timeoutMs);
      timeoutId.unref();
    }

    const exitCode = await new Promise<number | null>((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => resolve(code));
    }).finally(() => {
      this.activeExec.delete(opts.executionId);
      if (timeoutId) clearTimeout(timeoutId);
    });

    const result = {
      ok: !procState.timedOut && (exitCode ?? 0) === 0,
      exitCode,
      durationMs: Math.max(0, Date.now() - startedAt),
      stdout,
      stderr,
      executionId: opts.executionId,
      completedAt: new Date().toISOString(),
      ...(procState.timedOut ? { error: "Command timed out" } : {}),
    };

    this.emit("runtime.exec.completed", {
      projectId: opts.projectId,
      sessionId: opts.sessionId,
      threadId: opts.threadId,
      turnId: opts.turnId,
      itemId: opts.itemId,
      ...result,
    });

    return result;
  }

  private async runtimeExecCancel(executionId: string): Promise<boolean> {
    const active = this.activeExec.get(executionId);
    if (!active) return false;
    try {
      active.child.kill("SIGTERM");
      return true;
    } catch {
      return false;
    }
  }

  private async runtimeFsList(
    projectId: string,
    workspacePath: string | undefined,
    inputPath: string,
    opts: { recursive: boolean; includeHidden: boolean; limit: number }
  ) {
    const projectRoot = path.resolve(this.projectRoot(projectId, workspacePath));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const canonicalProjectRoot = await realpath(projectRoot).catch(() => projectRoot);
    const startPath = await this.resolveProjectPath(projectId, workspacePath, inputPath || ".");
    const entries: Array<{ path: string; type: "file" | "dir"; sizeBytes?: number; modifiedAt?: string }> = [];
    const queue: string[] = [];
    const maxEntries = Math.max(1, Math.min(20_000, Math.floor(opts.limit)));

    const enqueueDirectory = async (absDir: string) => {
      const list = await readdir(absDir, { withFileTypes: true });
      for (const dirent of list) {
        if (!opts.includeHidden && dirent.name.startsWith(".")) continue;
        const absPath = path.join(absDir, dirent.name);
        const resolved = dirent.isSymbolicLink() ? await realpath(absPath) : absPath;
        this.assertAllowedProjectPath(projectId, workspacePath, resolved);
        const resolvedStat = await stat(resolved);
        const relPath = path.relative(canonicalProjectRoot, absPath).replaceAll(path.sep, "/");
        if (!relPath || relPath.startsWith("..")) continue;
        const isDir = resolvedStat.isDirectory();
        entries.push({
          path: relPath,
          type: isDir ? "dir" : "file",
          ...(resolvedStat.isFile() ? { sizeBytes: resolvedStat.size } : {}),
          modifiedAt: resolvedStat.mtime.toISOString(),
        });
        if (entries.length >= maxEntries) return;
        if (isDir && opts.recursive) {
          queue.push(absPath);
        }
      }
    };

    const startStat = await stat(startPath);
    if (startStat.isDirectory()) {
      queue.push(startPath);
      while (queue.length > 0 && entries.length < maxEntries) {
        const current = queue.shift();
        if (!current) break;
        await enqueueDirectory(current);
      }
    } else {
      const relPath = path.relative(canonicalProjectRoot, startPath).replaceAll(path.sep, "/");
      if (relPath && !relPath.startsWith("..")) {
        entries.push({
          path: relPath,
          type: "file",
          sizeBytes: startStat.size,
          modifiedAt: startStat.mtime.toISOString(),
        });
      }
    }

    entries.sort((a, b) => a.path.localeCompare(b.path));
    return { entries };
  }

  private async runtimeFsStat(projectId: string, workspacePath: string | undefined, inputPath: string) {
    const abs = await this.resolveProjectPath(projectId, workspacePath, inputPath);
    const st = await stat(abs);
    return {
      path: abs,
      exists: true,
      type: st.isDirectory() ? "dir" : "file",
      sizeBytes: st.size,
      modifiedAt: st.mtime.toISOString(),
    };
  }

  private async runtimeFsRead(
    projectId: string,
    workspacePath: string | undefined,
    inputPath: string,
    offset: number,
    length: number,
    encoding: string
  ) {
    const abs = await this.resolveProjectPath(projectId, workspacePath, inputPath);
    const fh = await open(abs, "r");
    try {
      const st = await fh.stat();
      const buf = Buffer.alloc(Math.max(0, length));
      const { bytesRead } = await fh.read(buf, 0, buf.length, offset);
      const sliced = buf.subarray(0, bytesRead);
      return {
        path: abs,
        data: encoding === "base64" ? sliced.toString("base64") : sliced.toString("utf8"),
        eof: offset + bytesRead >= st.size,
      };
    } finally {
      await fh.close();
    }
  }

  private async runtimeFsWrite(
    projectId: string,
    workspacePath: string | undefined,
    inputPath: string,
    data: string,
    encoding: string,
    permissionLevel: PermissionLevel
  ) {
    const abs = await this.resolveProjectPath(projectId, workspacePath, inputPath, { forWrite: true });
    this.assertRuntimePathPolicy(projectId, workspacePath, abs, permissionLevel);
    await mkdir(path.dirname(abs), { recursive: true });
    if (encoding === "base64") {
      await writeFile(abs, Buffer.from(data, "base64"));
    } else {
      await writeFile(abs, data, "utf8");
    }
    const st = await stat(abs);
    return {
      ok: true,
      path: abs,
      sizeBytes: st.size,
      modifiedAt: st.mtime.toISOString(),
    };
  }

  private async runtimeFsDiff(projectId: string, workspacePath: string | undefined, paths: string[]) {
    const projectRoot = path.resolve(this.projectRoot(projectId, workspacePath));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const args = ["-C", projectRoot, "diff", "--no-color", "--"];
    for (const entry of paths) {
      const abs = await this.resolveProjectPath(projectId, workspacePath, entry, { forWrite: true });
      args.push(path.relative(projectRoot, abs).replaceAll(path.sep, "/"));
    }
    try {
      const { stdout } = await execFileAsync("git", args);
      return { diff: String(stdout ?? "") };
    } catch {
      return { diff: "" };
    }
  }

  private async runtimeFsApplyPatch(opts: {
    projectId: string;
    workspacePath?: string;
    sessionId: string;
    threadId: string;
    turnId: string;
    itemId: string;
    patchId: string;
    patch?: string;
    fileChanges?: Record<string, unknown>;
    permissionLevel: PermissionLevel;
  }) {
    const projectRoot = path.resolve(this.projectRoot(opts.projectId, opts.workspacePath));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const patchText = opts.patch ?? renderPatchFromFileChanges(opts.fileChanges ?? {});
    if (!patchText.trim()) {
      throw new Error("Patch is empty");
    }

    const changedPaths = extractChangedPathsFromPatch(patchText);
    for (const relPath of changedPaths) {
      const abs = await this.resolveProjectPath(opts.projectId, opts.workspacePath, relPath, { forWrite: true });
      this.assertRuntimePathPolicy(opts.projectId, opts.workspacePath, abs, opts.permissionLevel);
    }

    const tmpDir = await mkdtemp(path.join(os.tmpdir(), "epoch-local-patch-"));
    const patchPath = path.join(tmpDir, `${opts.patchId}.patch`);
    await writeFile(patchPath, patchText, "utf8");

    let applied = false;
    let error: string | null = null;
    try {
      await execFileAsync("git", ["-C", projectRoot, "apply", "--whitespace=nowarn", patchPath]);
      applied = true;
    } catch (err: any) {
      error = String(err?.stderr ?? err?.message ?? "git apply failed");
      try {
        await execFileAsync("patch", ["-p1", "-i", patchPath], { cwd: projectRoot });
        applied = true;
        error = null;
      } catch (patchErr: any) {
        error = String(patchErr?.stderr ?? patchErr?.message ?? error);
      }
    } finally {
      await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    }

    const diffRes = await this.runtimeFsDiff(opts.projectId, opts.workspacePath, changedPaths);
    const diffText = String(diffRes.diff ?? "") || patchText;

    for (const changedPath of changedPaths) {
      const perPathDiff = diffForSinglePath(diffText, changedPath);
      this.emit("runtime.fs.changed", {
        projectId: opts.projectId,
        sessionId: opts.sessionId,
        threadId: opts.threadId,
        turnId: opts.turnId,
        itemId: opts.itemId,
        patchId: opts.patchId,
        changeId: `${opts.patchId}:${changedPath}`,
        path: changedPath,
        kind: "update",
        ...(perPathDiff ? { diff: perPathDiff } : {}),
        ts: new Date().toISOString(),
      });
    }

    this.emit("runtime.fs.patchCompleted", {
      projectId: opts.projectId,
      sessionId: opts.sessionId,
      threadId: opts.threadId,
      turnId: opts.turnId,
      itemId: opts.itemId,
      patchId: opts.patchId,
      applied,
      changedPaths,
      ...(diffText ? { diff: diffText } : {}),
      ...(error ? { error } : {}),
      ts: new Date().toISOString(),
    });

    return {
      ok: applied,
      applied,
      patchId: opts.patchId,
      changedPaths,
      diff: diffText,
      ...(error ? { error } : {}),
      completedAt: new Date().toISOString(),
    };
  }

  private async shellExec(opts: {
    projectId: string;
    workspacePath?: string;
    runId: string;
    command: string[];
    cwd?: string;
    env?: Record<string, string>;
    timeoutMs?: number;
    permissionLevel: PermissionLevel;
  }) {
    if (!opts.projectId || !opts.runId || opts.command.length === 0) {
      throw new Error("Missing projectId/runId or command");
    }
    if (opts.permissionLevel !== "full") {
      throw new Error("shell.exec requires full permission");
    }
    const projectRoot = path.resolve(this.projectRoot(opts.projectId, opts.workspacePath));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const cwd = opts.cwd
      ? await this.resolveProjectPath(opts.projectId, opts.workspacePath, opts.cwd, { forWrite: true })
      : projectRoot;
    const { stdout, stderr } = await execFileAsync(opts.command[0]!, opts.command.slice(1), {
      cwd,
      env: { ...process.env, ...(opts.env ?? {}) },
      timeout: opts.timeoutMs,
    });
    if (stdout) {
      this.emit("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stdout", delta: String(stdout) });
    }
    if (stderr) {
      this.emit("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stderr", delta: String(stderr) });
    }
    const artifacts = await this.scanArtifacts(opts.projectId, opts.workspacePath, "artifacts");
    this.emit("artifacts.updated", { projectId: opts.projectId, artifacts });
    return {
      ok: true,
      exitCode: 0,
      startedAt: new Date().toISOString(),
      completedAt: new Date().toISOString(),
      durationMs: 0,
      stdout: String(stdout ?? ""),
      stderr: String(stderr ?? ""),
      artifacts,
    };
  }

  private async scanArtifacts(projectId: string, workspacePath: string | undefined, root: string) {
    const dir = path.join(this.projectRoot(projectId, workspacePath), root);
    try {
      const items = await readdir(dir, { withFileTypes: true });
      const artifacts: Array<{ path: string; sizeBytes: number; modifiedAt: string }> = [];
      for (const entry of items) {
        if (entry.isDirectory()) continue;
        const abs = path.join(dir, entry.name);
        const st = await stat(abs);
        artifacts.push({
          path: `${root}/${entry.name}`,
          sizeBytes: st.size,
          modifiedAt: st.mtime.toISOString(),
        });
      }
      return artifacts;
    } catch {
      return [];
    }
  }

  private async logsTail(absPath: string, sinceOffset: number) {
    const res = await this.fsReadRange(absPath, sinceOffset, 64 * 1024, "utf8");
    const data = String(res.data ?? "");
    return {
      data,
      nextOffset: sinceOffset + Buffer.byteLength(data, "utf8"),
    };
  }

  private async fsList(absPath: string) {
    this.assertAllowedPath(absPath);
    const items = await readdir(absPath, { withFileTypes: true });
    const entries: Array<{ path: string; type: "file" | "dir"; sizeBytes?: number; modifiedAt?: string }> = [];
    for (const item of items) {
      const entryPath = path.join(absPath, item.name);
      if (item.isDirectory()) {
        entries.push({ path: entryPath, type: "dir" });
        continue;
      }
      const st = await stat(entryPath);
      entries.push({ path: entryPath, type: "file", sizeBytes: st.size, modifiedAt: st.mtime.toISOString() });
    }
    return entries;
  }

  private async fsReadRange(absPath: string, offset: number, length: number, encoding: string) {
    this.assertAllowedPath(absPath);
    const fh = await open(absPath, "r");
    try {
      const st = await fh.stat();
      const buf = Buffer.alloc(Math.max(0, length));
      const { bytesRead } = await fh.read(buf, 0, buf.length, offset);
      const sliced = buf.subarray(0, bytesRead);
      return {
        data: encoding === "base64" ? sliced.toString("base64") : sliced.toString("utf8"),
        eof: offset + bytesRead >= st.size,
      };
    } finally {
      await fh.close();
    }
  }

  private async ensureProjectWorkspaceDirs(projectRoot: string) {
    await mkdir(projectRoot, { recursive: true });
    await mkdir(path.join(projectRoot, "artifacts"), { recursive: true });
    await mkdir(path.join(projectRoot, "runs"), { recursive: true });
    await mkdir(path.join(projectRoot, "logs"), { recursive: true });
  }

  private projectRoot(projectId: string, workspacePath?: string) {
    if (!/^[A-Za-z0-9._-]+$/.test(projectId)) {
      throw new Error(`Invalid projectId: ${projectId}`);
    }
    if (workspacePath) {
      return path.resolve(workspacePath);
    }
    const remembered = this.projectPaths.get(projectId);
    if (remembered) {
      return remembered;
    }
    return path.join(this.opts.workspaceRoot, "projects", projectId);
  }

  private async resolveProjectPath(
    projectId: string,
    workspacePath: string | undefined,
    inputPath: string,
    opts?: { forWrite?: boolean }
  ): Promise<string> {
    const projectRoot = path.resolve(this.projectRoot(projectId, workspacePath));
    const canonicalProjectRoot = await realpath(projectRoot).catch(() => projectRoot);
    const normalizedInput = inputPath.trim();
    if (!normalizedInput) {
      throw new Error("path is required");
    }

    const candidate = path.isAbsolute(normalizedInput)
      ? path.resolve(normalizedInput)
      : path.resolve(projectRoot, normalizedInput);

    const guardRoot = (resolvedBase: string) => {
      if (!resolvedBase.startsWith(canonicalProjectRoot + path.sep) && resolvedBase !== canonicalProjectRoot) {
        throw new Error(`Path outside project workspace: ${inputPath}`);
      }
    };

    if (opts?.forWrite) {
      let cursor = path.resolve(candidate);
      while (true) {
        try {
          guardRoot(await realpath(cursor));
          break;
        } catch (err: any) {
          if (err?.code !== "ENOENT") throw err;
          const parent = path.dirname(cursor);
          if (parent === cursor) break;
          cursor = parent;
        }
      }
      try {
        const st = await lstat(candidate);
        if (st.isSymbolicLink()) {
          guardRoot(await realpath(candidate));
        }
      } catch (err: any) {
        if (err?.code !== "ENOENT") throw err;
      }
      return candidate;
    }

    const resolved = await realpath(candidate);
    guardRoot(resolved);
    return resolved;
  }

  private assertAllowedPath(absPath: string) {
    const root = path.resolve(this.opts.workspaceRoot);
    const full = path.resolve(absPath);
    if (!full.startsWith(root + path.sep) && full !== root) {
      throw new Error(`Path outside workspaceRoot: ${absPath}`);
    }
  }

  private assertAllowedProjectPath(projectId: string, workspacePath: string | undefined, absPath: string) {
    const projectRoot = path.resolve(this.projectRoot(projectId, workspacePath));
    const full = path.resolve(absPath);
    if (!full.startsWith(projectRoot + path.sep) && full !== projectRoot) {
      throw new Error(`Path outside projectRoot: ${absPath}`);
    }
  }

  private assertRuntimePathPolicy(
    projectId: string,
    workspacePath: string | undefined,
    absPath: string,
    permissionLevel: PermissionLevel
  ) {
    this.assertAllowedProjectPath(projectId, workspacePath, absPath);
    const rel = path.relative(this.projectRoot(projectId, workspacePath), absPath).replaceAll(path.sep, "/");
    if (permissionLevel === "default" && (rel === ".git" || rel.startsWith(".git/"))) {
      throw new Error("Default permission does not allow writes under .git/");
    }
  }

  private assertRuntimeCommandPolicy(command: string[], permissionLevel: PermissionLevel) {
    const bin = String(command[0] ?? "").trim();
    if (!bin) {
      throw new Error("command is required");
    }
    const base = path.basename(bin);
    if (DANGEROUS_COMMANDS.has(base)) {
      throw new Error(`Command blocked by policy: ${base}`);
    }
    if (permissionLevel === "full") return;
    if (!DEFAULT_ALLOWED_BINARIES.has(base)) {
      throw new Error(`Command not allowed in default permission: ${base}`);
    }
    if (SHELL_BINARIES.has(base)) {
      const dashC = command.indexOf("-c");
      if (dashC === -1) return;
      const script = command[dashC + 1] ?? "";
      if (/[|;&><]/.test(script)) {
        throw new Error("Shell pipelines/redirection are not allowed in default permission");
      }
    }
  }

  private async readCpuPercent(): Promise<number> {
    let sample: ProcCpuSample | null = null;
    try {
      sample = parseProcStatSample(await readFile("/proc/stat", "utf8"));
    } catch {
      sample = sampleCpuFromOsCpus(os.cpus());
    }
    if (!sample) return 0;
    const previous = this.prevCpuSample;
    this.prevCpuSample = sample;
    if (!previous) return 0;
    return computeCpuPercentFromSamples(previous, sample);
  }

  private async readRamPercent(): Promise<number> {
    try {
      const parsed = parseMemInfoUsagePercent(await readFile("/proc/meminfo", "utf8"));
      if (parsed != null) return parsed;
    } catch {
      // fall through
    }
    return computeRamPercentFromTotals(os.totalmem(), os.freemem()) ?? 0;
  }

  private async readGpuPercent(): Promise<number | undefined> {
    try {
      const { stdout } = await execFileAsync("nvidia-smi", ["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"]);
      return parseNvidiaSmiUtilizationPercent(String(stdout ?? ""));
    } catch {
      return undefined;
    }
  }
}

function normalizePermissionLevel(raw: unknown): PermissionLevel | null {
  const value = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (value === "default") return "default";
  if (value === "full") return "full";
  return null;
}

function normalizeSandboxMode(raw: unknown): RuntimeSandboxMode {
  const value = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (value === "danger-full-access") return "danger-full-access";
  if (value === "read-only") return "read-only";
  return "workspace-write";
}

function normalizePositiveInteger(raw: unknown): number | undefined {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return undefined;
  const value = Math.floor(parsed);
  return value > 0 ? value : undefined;
}

function normalizeNonNegativeInteger(raw: unknown): number | undefined {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return undefined;
  const value = Math.floor(parsed);
  return value >= 0 ? value : undefined;
}

function normalizeOptionalString(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  const trimmed = raw.trim();
  return trimmed ? trimmed : undefined;
}

function normalizeStringRecord(raw: unknown): Record<string, string> | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  return Object.fromEntries(Object.entries(raw).map(([key, value]) => [String(key), String(value ?? "")]));
}

function renderPatchFromFileChanges(fileChanges: Record<string, unknown>): string {
  const chunks: string[] = [];
  for (const [filePath, rawChange] of Object.entries(fileChanges)) {
    if (!rawChange || typeof rawChange !== "object" || Array.isArray(rawChange)) continue;
    const change = rawChange as Record<string, unknown>;
    const type = String(change.type ?? "").trim().toLowerCase();
    if (!filePath.trim() || !type) continue;
    if (type === "update") {
      const unified = String(change.unified_diff ?? "");
      if (unified.trim()) {
        chunks.push(unified.endsWith("\n") ? unified : `${unified}\n`);
      }
      continue;
    }
    const content = String(change.content ?? "");
    const lines = content.split(/\r?\n/);
    if (type === "add") {
      chunks.push(`diff --git a/${filePath} b/${filePath}`);
      chunks.push("new file mode 100644");
      chunks.push("--- /dev/null");
      chunks.push(`+++ b/${filePath}`);
      chunks.push(`@@ -0,0 +1,${lines.length} @@`);
      for (const line of lines) chunks.push(`+${line}`);
      continue;
    }
    if (type === "delete") {
      chunks.push(`diff --git a/${filePath} b/${filePath}`);
      chunks.push("deleted file mode 100644");
      chunks.push(`--- a/${filePath}`);
      chunks.push("+++ /dev/null");
      chunks.push(`@@ -1,${lines.length} +0,0 @@`);
      for (const line of lines) chunks.push(`-${line}`);
    }
  }
  return chunks.join("\n").trim() ? `${chunks.join("\n")}\n` : "";
}

function extractChangedPathsFromPatch(patchText: string): string[] {
  const out = new Set<string>();
  for (const line of patchText.split(/\r?\n/)) {
    if (line.startsWith("+++ b/")) {
      const value = line.slice("+++ b/".length).trim();
      if (value && value !== "/dev/null") out.add(value);
      continue;
    }
    if (line.startsWith("--- a/")) {
      const value = line.slice("--- a/".length).trim();
      if (value && value !== "/dev/null") out.add(value);
    }
  }
  return [...out];
}

function diffForSinglePath(fullDiff: string, filePath: string): string {
  if (!fullDiff.trim()) return "";
  const normalized = filePath.replaceAll("\\", "/");
  const sections = fullDiff.split(/^diff --git /m);
  const matches = sections.filter((section) => section.includes(` a/${normalized} `) || section.includes(` b/${normalized}`));
  if (matches.length === 0) return "";
  return matches.map((section) => (section.startsWith("diff --git ") ? section : `diff --git ${section}`)).join("\n");
}
