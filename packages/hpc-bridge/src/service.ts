import { createHmac } from "node:crypto";
import { lstat, mkdtemp, mkdir, open, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import os from "node:os";

import WebSocket from "ws";
import { v4 as uuidv4 } from "uuid";
import { isNodeMethod, nodeMethods } from "@labos/protocol";

import type { BridgeConfig } from "./config.js";
import { collectStorageUsage } from "./storage-usage.js";

const execFileAsync = promisify(execFile);

type PendingRequest = {
  resolve: (payload: any) => void;
  reject: (err: Error) => void;
  timeout: NodeJS.Timeout;
};

type HpcPrefs = {
  partition?: string;
  account?: string;
  qos?: string;
};

type HpcTres = {
  cpu?: number;
  memMB?: number;
  gpus?: number;
};

type HpcStatus = {
  partition?: string;
  account?: string;
  qos?: string;
  runningJobs: number;
  pendingJobs: number;
  limit?: HpcTres;
  inUse?: HpcTres;
  available?: HpcTres;
  updatedAt: string;
};

type PermissionLevel = "default" | "full";

type RuntimePolicy = {
  exec?: {
    maxTimeoutMs?: number;
    maxConcurrent?: number;
  };
  slurm?: {
    maxTimeMinutes?: number;
    maxCpus?: number;
    maxMemMB?: number;
    maxGpus?: number;
    maxConcurrent?: number;
  };
};

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
  "srun",
  "sbatch",
  "squeue",
  "scancel",
]);

const SHELL_BINARIES = new Set(["bash", "sh", "zsh", "fish"]);

export class BridgeService {
  private ws: WebSocket | null = null;
  private seq = 0;
  private pending = new Map<string, PendingRequest>();

  private hpcPrefs: HpcPrefs = {};
  private readonly heartbeatIntervalMs = normalizePositiveInt(process.env.LABOS_HPC_HEARTBEAT_MS, 1_000);
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private heartbeatInFlight = false;
  private slurmUser: string | null = null;
  private limitCache: { key: string; fetchedAt: number; limit: HpcTres | null } = { key: "", fetchedAt: 0, limit: null };
  private runtimeExecActive = new Map<string, { child: ReturnType<typeof spawn>; startedAtMs: number; timedOut: boolean }>();

  public constructor(private cfg: BridgeConfig) {
    this.hpcPrefs = {
      partition: cfg.defaults.partition,
      account: cfg.defaults.account,
      qos: cfg.defaults.qos,
    };
  }

  public async start() {
    const ws = new WebSocket(this.cfg.hubUrl);
    this.ws = ws;

    ws.on("open", () => {
      // wait for connect.challenge
    });

    ws.on("message", (data) => {
      void this.onMessage(data.toString("utf8"));
    });

    ws.on("close", (code, reason) => {
      // eslint-disable-next-line no-console
      console.error(`bridge disconnected (${code}): ${reason.toString()}`);
      process.exitCode = 1;
    });

    await new Promise<void>((resolve, reject) => {
      ws.on("error", reject);
      ws.on("open", () => resolve());
    });

    // Keep alive
    await new Promise(() => {});
  }

  private send(obj: any) {
    if (!this.ws) return;
    this.ws.send(JSON.stringify(obj));
  }

  private sendEvent(event: string, payload: any) {
    this.send({ type: "event", event, payload, seq: this.seq++, ts: new Date().toISOString() });
  }

  private async onMessage(text: string) {
    let msg: any;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }

    if (msg.type === "event" && msg.event === "connect.challenge") {
      await this.handleChallenge(msg.payload ?? {});
      return;
    }

    if (msg.type === "res") {
      const pending = this.pending.get(msg.id);
      if (!pending) return;
      clearTimeout(pending.timeout);
      this.pending.delete(msg.id);
      if (msg.ok) pending.resolve(msg.payload ?? {});
      else pending.reject(new Error(msg?.error?.message ?? "request failed"));
      return;
    }

    if (msg.type === "req") {
      await this.handleRequest(msg);
      return;
    }
  }

  private async handleChallenge(payload: any) {
    const nonce = String(payload.nonce ?? "");
    const signature = createHmac("sha256", this.cfg.token).update(nonce).digest("base64url");

    this.send({
      type: "req",
      id: uuidv4(),
      method: "connect",
      params: {
        minProtocol: 1,
        maxProtocol: 1,
        role: "node",
        auth: { token: this.cfg.token, signature },
        device: {
          id: this.cfg.nodeId,
          name: "LabOS HPC Bridge",
          platform: process.platform,
          osVersion: process.version,
        },
        client: { name: "@labos/hpc-bridge", version: "0.1.0" },
        caps: ["slurm", "fs", "artifacts", "logs", "shell"],
        commands: [...nodeMethods],
        permissions: {
          workspaceRoot: this.cfg.workspaceRoot,
          defaults: this.cfg.defaults,
        },
      },
    });

    this.startHeartbeatLoop();
  }

  private startHeartbeatLoop() {
    if (this.heartbeatTimer) return;
    const tick = () => void this.sendHeartbeat();
    this.heartbeatTimer = setInterval(tick, this.heartbeatIntervalMs);
    this.heartbeatTimer.unref();
    tick();
  }

  private async sendHeartbeat() {
    if (this.heartbeatInFlight) return;
    this.heartbeatInFlight = true;
    try {
      const hpc = await this.collectHpcStatus().catch(() => null);
      const storage = await collectStorageUsage(this.cfg.workspaceRoot).catch(() => null);
      this.sendEvent("node.heartbeat", {
        nodeId: this.cfg.nodeId,
        ts: new Date().toISOString(),
        queueDepth: hpc?.pendingJobs ?? 0,
        storageUsedPercent: storage?.usedPercent ?? 0,
        storageTotalBytes: storage?.totalBytes,
        storageUsedBytes: storage?.usedBytes,
        storageAvailableBytes: storage?.availableBytes,
        cpuPercent: 0,
        ramPercent: 0,
        hpc,
      });
    } finally {
      this.heartbeatInFlight = false;
    }
  }

  private sendRes(id: string, ok: boolean, payload?: any, error?: any) {
    this.send({ type: "res", id, ok, payload, error });
  }

  private async collectHpcStatus(): Promise<HpcStatus | null> {
    const hasSqueue = await this.hasCommand("squeue");
    if (!hasSqueue) return null;

    const user = await this.getSlurmUser();
    const runningJobIds = await this.squeueJobIds({ user, state: "R" });
    const pendingJobs = (await this.squeueJobIds({ user, state: "PD" })).length;

    const inUse = await this.sumAllocatedTres({ user, runningJobIds }).catch(() => null);
    const limit = await this.getCachedLimitTres(user).catch(() => null);

    const available = limit && inUse ? subtractTres(limit, inUse) : undefined;

    return {
      partition: this.hpcPrefs.partition,
      account: this.hpcPrefs.account,
      qos: this.hpcPrefs.qos,
      runningJobs: runningJobIds.length,
      pendingJobs,
      limit: limit ?? undefined,
      inUse: inUse ?? undefined,
      available,
      updatedAt: new Date().toISOString(),
    };
  }

  private async getSlurmUser(): Promise<string> {
    if (this.slurmUser) return this.slurmUser;
    const envUser = process.env.USER ?? process.env.LOGNAME ?? "";
    if (envUser.trim()) {
      this.slurmUser = envUser.trim();
      return this.slurmUser;
    }
    try {
      const { stdout } = await execFileAsync("whoami", []);
      const u = String(stdout ?? "").trim();
      if (u) {
        this.slurmUser = u;
        return u;
      }
    } catch {
      // ignore
    }
    this.slurmUser = "unknown";
    return this.slurmUser;
  }

  private slurmFilterArgs(): string[] {
    const args: string[] = [];
    if (this.hpcPrefs.partition) args.push("-p", this.hpcPrefs.partition);
    if (this.hpcPrefs.account) args.push("-A", this.hpcPrefs.account);
    if (this.hpcPrefs.qos) args.push("-q", this.hpcPrefs.qos);
    return args;
  }

  private async squeueJobIds(opts: { user: string; state: "R" | "PD" }): Promise<string[]> {
    const { stdout } = await execFileAsync("squeue", ["-h", "-u", opts.user, "-t", opts.state, ...this.slurmFilterArgs(), "-o", "%A"]);
    return String(stdout ?? "")
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean);
  }

  private async sumAllocatedTres(opts: { user: string; runningJobIds: string[] }): Promise<HpcTres | null> {
    if (opts.runningJobIds.length === 0) return { cpu: 0, memMB: 0, gpus: 0 };

    const fromJson = await this.sumAllocatedTresFromSqueueJson(opts.user).catch(() => null);
    if (fromJson) return fromJson;

    const fromScontrol = await this.sumAllocatedTresFromScontrol(opts.runningJobIds).catch(() => null);
    return fromScontrol;
  }

  private async sumAllocatedTresFromSqueueJson(user: string): Promise<HpcTres | null> {
    const { stdout } = await execFileAsync("squeue", ["--json", "-u", user, "-t", "R", ...this.slurmFilterArgs()]);
    let parsed: any;
    try {
      parsed = JSON.parse(String(stdout ?? ""));
    } catch {
      return null;
    }
    const jobs = Array.isArray(parsed?.jobs) ? parsed.jobs : Array.isArray(parsed?.data?.jobs) ? parsed.data.jobs : null;
    if (!jobs) return null;

    let sum: HpcTres = {};
    for (const j of jobs) {
      const rawTres = typeof j?.tres_alloc_str === "string" ? j.tres_alloc_str : typeof j?.tres_allocated_str === "string" ? j.tres_allocated_str : null;
      if (rawTres) {
        sum = addTres(sum, parseTresString(rawTres));
        continue;
      }
      const cpu = typeof j?.cpus === "number" ? j.cpus : Number(j?.cpus);
      if (Number.isFinite(cpu) && cpu > 0) sum.cpu = (sum.cpu ?? 0) + cpu;
    }
    return sum;
  }

  private async sumAllocatedTresFromScontrol(jobIds: string[]): Promise<HpcTres | null> {
    const { stdout } = await execFileAsync("scontrol", ["show", "job", ...jobIds, "-o"]);
    const lines = String(stdout ?? "")
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter(Boolean);
    if (lines.length === 0) return null;

    let sum: HpcTres = {};
    for (const line of lines) {
      sum = addTres(sum, parseScontrolJobLineTres(line));
    }
    return sum;
  }

  private async getCachedLimitTres(user: string): Promise<HpcTres | null> {
    const key = `${user}|${this.hpcPrefs.account ?? ""}|${this.hpcPrefs.qos ?? ""}`;
    const now = Date.now();
    if (this.limitCache.key === key && now - this.limitCache.fetchedAt < 60_000) {
      return this.limitCache.limit;
    }

    if (!this.hpcPrefs.account && !this.hpcPrefs.qos) {
      this.limitCache = { key, fetchedAt: now, limit: null };
      return null;
    }

    const has = await this.hasCommand("sacctmgr");
    if (!has) {
      this.limitCache = { key, fetchedAt: now, limit: null };
      return null;
    }

    const qosLimit = this.hpcPrefs.qos ? await this.fetchQosLimitTres(this.hpcPrefs.qos) : null;
    const assocLimit =
      this.hpcPrefs.account && user !== "unknown" ? await this.fetchAssocLimitTres({ user, account: this.hpcPrefs.account }) : null;
    const limit = minTres(qosLimit, assocLimit);

    this.limitCache = { key, fetchedAt: now, limit };
    return limit;
  }

  private async fetchQosLimitTres(qos: string): Promise<HpcTres | null> {
    const out = await this.tryCommand("sacctmgr", ["-n", "-P", "show", "qos", qos, "format=MaxTRESPerUser"]);
    const line = firstNonEmptyLine(out);
    if (!line) return null;
    const parsed = parseTresString(line);
    return isEmptyTres(parsed) ? null : parsed;
  }

  private async fetchAssocLimitTres(opts: { user: string; account: string }): Promise<HpcTres | null> {
    const out = await this.tryCommand("sacctmgr", [
      "-n",
      "-P",
      "show",
      "assoc",
      "where",
      `user=${opts.user}`,
      `account=${opts.account}`,
      "format=MaxTRES,GrpTRES",
    ]);
    const line = firstNonEmptyLine(out);
    if (!line) return null;
    const [maxTRES, grpTRES] = line.split("|", 2);
    const maxParsed = parseTresString(maxTRES ?? "");
    if (!isEmptyTres(maxParsed)) return maxParsed;
    const grpParsed = parseTresString(grpTRES ?? "");
    return isEmptyTres(grpParsed) ? null : grpParsed;
  }

  private async tryCommand(bin: string, args: string[]): Promise<string | null> {
    try {
      const { stdout } = await execFileAsync(bin, args, { env: { ...process.env, LC_ALL: "C" } });
      return String(stdout ?? "");
    } catch {
      return null;
    }
  }

  private async handleRequest(req: any) {
    const id = String(req.id ?? "");
    const method = String(req.method ?? "");
    const params = req.params ?? {};

    try {
      if (!isNodeMethod(method)) {
        this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: `Unknown method: ${method}` });
        return;
      }
      switch (method) {
        case "fs.list": {
          const p = String(params.path ?? "");
          const entries = await this.fsList(p);
          this.sendRes(id, true, { entries });
          return;
        }
        case "fs.readRange": {
          const p = String(params.path ?? "");
          const offset = Number(params.offset ?? 0);
          const length = Number(params.length ?? 0);
          const encoding = String(params.encoding ?? "utf8");
          const res = await this.fsReadRange(p, offset, length, encoding);
          this.sendRes(id, true, res);
          return;
        }
        case "runtime.exec.start": {
          const projectId = String(params.projectId ?? "").trim();
          const sessionId = String(params.sessionId ?? "").trim();
          const threadId = String(params.threadId ?? "").trim();
          const turnId = String(params.turnId ?? "").trim();
          const itemId = String(params.itemId ?? "").trim();
          const executionId = String(params.executionId ?? uuidv4()).trim();
          const command = Array.isArray(params.command) ? params.command.map(String).filter(Boolean) : [];
          const cwd = params.cwd == null ? undefined : String(params.cwd);
          const timeoutMs = typeof params.timeoutMs === "number" ? Math.max(1, Math.floor(params.timeoutMs)) : undefined;
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          const policyOverride = normalizeRuntimePolicy(params.policy);
          const sandboxMode = normalizeSandboxMode(params.sandboxMode);
          const env = params.env && typeof params.env === "object" ? (params.env as Record<string, unknown>) : undefined;
          const cleanEnv: Record<string, string> | undefined = env
            ? Object.fromEntries(Object.entries(env).map(([k, v]) => [String(k), String(v ?? "")]))
            : undefined;

          if (!projectId || !sessionId || !threadId || !turnId || !itemId || !executionId || command.length === 0) {
            this.sendRes(id, false, undefined, {
              code: "BAD_REQUEST",
              message: "runtime.exec.start requires projectId/sessionId/threadId/turnId/itemId/executionId and non-empty command",
            });
            return;
          }

          const policy = this.runtimePolicyFor(policyOverride);
          if (policy?.exec?.maxConcurrent != null &&
              this.runtimeExecActive.size >= policy.exec.maxConcurrent) {
            this.sendRes(id, false, undefined, {
              code: "RATE_LIMITED",
              message: `runtime.exec.start concurrency exceeded (${policy.exec.maxConcurrent})`,
            });
            return;
          }

          const result = await this.runtimeExecStart({
            projectId,
            sessionId,
            threadId,
            turnId,
            itemId,
            executionId,
            command,
            cwd,
            env: cleanEnv,
            timeoutMs,
            permissionLevel,
            policyOverride,
            sandboxMode,
          });
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.exec.cancel": {
          const executionId = String(params.executionId ?? "").trim();
          if (!executionId) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.exec.cancel requires executionId" });
            return;
          }
          const cancelled = await this.runtimeExecCancel(executionId);
          this.sendRes(id, true, { ok: true, cancelled });
          return;
        }
        case "runtime.fs.stat": {
          const projectId = String(params.projectId ?? "").trim();
          const inputPath = String(params.path ?? "");
          if (!projectId || !inputPath) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.fs.stat requires projectId/path" });
            return;
          }
          const result = await this.runtimeFsStat(projectId, inputPath);
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.fs.read": {
          const projectId = String(params.projectId ?? "").trim();
          const inputPath = String(params.path ?? "");
          const offset = typeof params.offset === "number" ? Math.max(0, Math.floor(params.offset)) : 0;
          const length = typeof params.length === "number" ? Math.max(0, Math.floor(params.length)) : 64 * 1024;
          const encoding = String(params.encoding ?? "utf8");
          if (!projectId || !inputPath) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.fs.read requires projectId/path" });
            return;
          }
          const result = await this.runtimeFsRead(projectId, inputPath, offset, length, encoding);
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.fs.write": {
          const projectId = String(params.projectId ?? "").trim();
          const inputPath = String(params.path ?? "");
          const data = String(params.data ?? "");
          const encoding = String(params.encoding ?? "utf8");
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          if (!projectId || !inputPath) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.fs.write requires projectId/path" });
            return;
          }
          const result = await this.runtimeFsWrite(projectId, inputPath, data, encoding, permissionLevel);
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.fs.list": {
          const projectId = String(params.projectId ?? "").trim();
          const inputPath = String(params.path ?? ".");
          const recursive = params.recursive == null ? true : Boolean(params.recursive);
          const includeHidden = Boolean(params.includeHidden ?? false);
          const limit = Number.isFinite(Number(params.limit)) ? Math.max(1, Math.floor(Number(params.limit))) : 3_000;
          if (!projectId) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.fs.list requires projectId" });
            return;
          }
          const result = await this.runtimeFsList(projectId, inputPath, {
            recursive,
            includeHidden,
            limit,
          });
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.fs.diff": {
          const projectId = String(params.projectId ?? "").trim();
          const paths = Array.isArray(params.paths) ? params.paths.map(String).filter(Boolean) : [];
          if (!projectId) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "runtime.fs.diff requires projectId" });
            return;
          }
          const result = await this.runtimeFsDiff(projectId, paths);
          this.sendRes(id, true, result);
          return;
        }
        case "runtime.fs.applyPatch": {
          const projectId = String(params.projectId ?? "").trim();
          const sessionId = String(params.sessionId ?? "").trim();
          const threadId = String(params.threadId ?? "").trim();
          const turnId = String(params.turnId ?? "").trim();
          const itemId = String(params.itemId ?? "").trim();
          const patchId = String(params.patchId ?? uuidv4()).trim();
          const patch = normalizeOptionalString(params.patch) ?? normalizeOptionalString(params.unifiedDiff) ?? normalizeOptionalString(params.unified_diff);
          const fileChanges = params.fileChanges && typeof params.fileChanges === "object" ? (params.fileChanges as Record<string, unknown>) : null;
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          if (!projectId || !sessionId || !threadId || !turnId || !itemId || !patchId || (!patch && !fileChanges)) {
            this.sendRes(id, false, undefined, {
              code: "BAD_REQUEST",
              message: "runtime.fs.applyPatch requires project/session/thread/turn/item ids and patch or fileChanges",
            });
            return;
          }
          const result = await this.runtimeFsApplyPatch({
            projectId,
            sessionId,
            threadId,
            turnId,
            itemId,
            patchId,
            patch: patch ?? undefined,
            fileChanges: fileChanges ?? undefined,
            permissionLevel,
          });
          this.sendRes(id, true, result);
          return;
        }
        case "slurm.submit": {
          const projectId = String(params.projectId ?? "");
          const runId = String(params.runId ?? "");
          const job = params.job ?? {};
          const staging = params.staging ?? { uploads: [] };
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          const policyOverride = normalizeRuntimePolicy(params.policy);
          const result = await this.slurmSubmit({ projectId, runId, job, staging, permissionLevel, policyOverride });
          this.sendRes(id, true, result);
          return;
        }
        case "shell.exec": {
          const projectId = String(params.projectId ?? "");
          const runId = String(params.runId ?? "");
          const command = Array.isArray(params.command) ? params.command.map(String).filter(Boolean) : [];
          const cwd = params.cwd == null ? undefined : String(params.cwd);
          const timeoutMs = typeof params.timeoutMs === "number" ? Math.max(0, Math.floor(params.timeoutMs)) : undefined;
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          const env = params.env && typeof params.env === "object" ? (params.env as Record<string, unknown>) : undefined;
          const cleanEnv: Record<string, string> | undefined = env
            ? Object.fromEntries(Object.entries(env).map(([k, v]) => [String(k), String(v)]))
            : undefined;

          if (!projectId || !runId || command.length === 0) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "Missing projectId/runId or empty command" });
            return;
          }
          if (permissionLevel !== "full") {
            this.sendRes(id, false, undefined, { code: "PERMISSION_DENIED", message: "shell.exec requires full permission" });
            return;
          }

          const result = await this.shellExec({ projectId, runId, command, cwd, env: cleanEnv, timeoutMs, permissionLevel });
          this.sendRes(id, true, result);
          return;
        }
        case "slurm.status": {
          const jobId = String(params.jobId ?? "");
          const result = await this.slurmStatus(jobId);
          this.sendRes(id, true, result);
          return;
        }
        case "slurm.cancel": {
          const jobId = String(params.jobId ?? "");
          await this.slurmCancel(jobId);
          this.sendRes(id, true, { ok: true });
          return;
        }
        case "artifact.scan": {
          const projectId = String(params.projectId ?? "");
          const root = String(params.root ?? "artifacts");
          const artifacts = await this.scanArtifacts(projectId, root);
          this.sendRes(id, true, { artifacts });
          return;
        }
        case "logs.tail": {
          const p = String(params.path ?? "");
          const sinceOffset = Number(params.sinceOffset ?? 0);
          const res = await this.logsTail(p, sinceOffset);
          this.sendRes(id, true, res);
          return;
        }
        case "hpc.prefs.set": {
          const next: HpcPrefs = { ...this.hpcPrefs };
          if (Object.prototype.hasOwnProperty.call(params, "partition")) next.partition = normalizeOptionalString((params as any).partition);
          if (Object.prototype.hasOwnProperty.call(params, "account")) next.account = normalizeOptionalString((params as any).account);
          if (Object.prototype.hasOwnProperty.call(params, "qos")) next.qos = normalizeOptionalString((params as any).qos);
          this.hpcPrefs = next;
          this.limitCache = { key: "", fetchedAt: 0, limit: null };
          this.sendRes(id, true, { ok: true });
          return;
        }
        case "workspace.project.ensure": {
          const projectId = String(params.projectId ?? "").trim();
          if (!projectId) {
            this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: "Missing projectId" });
            return;
          }
          const root = this.projectRoot(projectId);
          await this.ensureProjectWorkspaceDirs(root);
          this.sendRes(id, true, {
            ok: true,
            projectId,
            workspacePath: root,
            updatedAt: new Date().toISOString(),
          });
          return;
        }
        default:
          this.sendRes(id, false, undefined, { code: "BAD_REQUEST", message: `Unknown method: ${method}` });
          return;
      }
    } catch (err: any) {
      this.sendRes(id, false, undefined, { code: "INTERNAL", message: err?.message ?? "internal error" });
    }
  }

  private assertAllowedPath(p: string) {
    const root = path.resolve(this.cfg.workspaceRoot);
    const full = path.resolve(p);
    if (!full.startsWith(root + path.sep) && full !== root) {
      throw new Error(`Path outside workspaceRoot: ${p}`);
    }
  }

  private assertAllowedProjectPath(projectId: string, p: string) {
    const projectRoot = path.resolve(this.projectRoot(projectId));
    const full = path.resolve(p);
    if (!full.startsWith(projectRoot + path.sep) && full !== projectRoot) {
      throw new Error(`Path outside projectRoot: ${p}`);
    }
  }

  private async fsList(absPath: string) {
    this.assertAllowedPath(absPath);
    const items = await readdir(absPath, { withFileTypes: true });
    const out: Array<{ path: string; type: "file" | "dir"; sizeBytes?: number; modifiedAt?: string }> = [];
    for (const it of items) {
      const p = path.join(absPath, it.name);
      if (it.isDirectory()) {
        out.push({ path: p, type: "dir" });
      } else {
        const st = await stat(p);
        out.push({ path: p, type: "file", sizeBytes: st.size, modifiedAt: st.mtime.toISOString() });
      }
    }
    return out;
  }

  private async fsReadRange(absPath: string, offset: number, length: number, encoding: string) {
    this.assertAllowedPath(absPath);
    const fh = await open(absPath, "r");
    try {
      const st = await fh.stat();
      const buf = Buffer.alloc(Math.max(0, length));
      const { bytesRead } = await fh.read(buf, 0, buf.length, offset);
      const sliced = buf.subarray(0, bytesRead);
      const data = encoding === "base64" ? sliced.toString("base64") : sliced.toString("utf8");
      return { data, eof: offset + bytesRead >= st.size };
    } finally {
      await fh.close();
    }
  }

  private runtimePolicyFor(override?: RuntimePolicy | null): RuntimePolicy | null {
    return override ?? null;
  }

  private async resolveProjectPath(projectId: string, inputPath: string, opts?: { forWrite?: boolean }): Promise<string> {
    const projectRoot = path.resolve(this.projectRoot(projectId));
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

    const nearestExistingRealPath = async (targetPath: string): Promise<string> => {
      let cursor = path.resolve(targetPath);
      while (true) {
        try {
          return await realpath(cursor);
        } catch (err: any) {
          if (err?.code !== "ENOENT") {
            throw err;
          }
          const parent = path.dirname(cursor);
          if (parent === cursor) {
            return cursor;
          }
          cursor = parent;
        }
      }
    };

    if (opts?.forWrite) {
      const parentRealPath = await nearestExistingRealPath(path.dirname(candidate));
      guardRoot(parentRealPath);
      try {
        const st = await lstat(candidate);
        if (st.isSymbolicLink()) {
          const resolvedTarget = await realpath(candidate);
          guardRoot(resolvedTarget);
          return candidate;
        }
      } catch (err: any) {
        if (err?.code !== "ENOENT") {
          throw err;
        }
      }
      return candidate;
    }

    const resolved = await realpath(candidate);
    guardRoot(resolved);
    return resolved;
  }

  private assertRuntimePathPolicy(projectId: string, absPath: string, permissionLevel: PermissionLevel) {
    this.assertAllowedProjectPath(projectId, absPath);
    const rel = path.relative(this.projectRoot(projectId), absPath).replaceAll(path.sep, "/");
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

    if (permissionLevel === "full") {
      return;
    }

    if (!DEFAULT_ALLOWED_BINARIES.has(base)) {
      throw new Error(`Command not allowed in default permission: ${base}`);
    }

    if (SHELL_BINARIES.has(base)) {
      const hasShellCommand = command.some((arg) => arg === "-c");
      if (!hasShellCommand) return;
      const script = command[command.indexOf("-c") + 1] ?? "";
      if (/[|;&><]/.test(script)) {
        throw new Error("Shell pipelines/redirection are not allowed in default permission");
      }
    }
  }

  private async runtimeExecStart(opts: {
    projectId: string;
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
    policyOverride?: RuntimePolicy | null;
    sandboxMode?: "workspace-write" | "danger-full-access" | "read-only";
  }) {
    this.assertRuntimeCommandPolicy(opts.command, opts.permissionLevel);

    const policy = this.runtimePolicyFor(opts.policyOverride);
    const cap = policy?.exec?.maxTimeoutMs;
    const timeoutMs = cap != null
      ? Math.min(opts.timeoutMs ?? cap, cap)
      : opts.timeoutMs;
    const projectRoot = path.resolve(this.projectRoot(opts.projectId));
    const resolvedCwd = resolveRuntimeCommandCwd({
      workspaceRoot: this.cfg.workspaceRoot,
      projectRoot,
      rawCwd: opts.cwd,
      fallbackCwd: projectRoot,
    });
    const cwd = await this.resolveProjectPath(opts.projectId, resolvedCwd, { forWrite: true });
    this.assertAllowedProjectPath(opts.projectId, cwd);

    const startedAt = Date.now();
    this.sendEvent("runtime.exec.started", {
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

    let finalEnv: NodeJS.ProcessEnv = { ...process.env, ...(opts.env ?? {}) };
    if (opts.sandboxMode === "workspace-write") {
      const wsEnv: Record<string, string> = {
        HOME: projectRoot,
        TMPDIR: path.join(projectRoot, "tmp"),
        XDG_CACHE_HOME: path.join(projectRoot, ".cache"),
        XDG_DATA_HOME: path.join(projectRoot, ".local", "share"),
        XDG_CONFIG_HOME: path.join(projectRoot, ".config"),
        PYTHONUSERBASE: path.join(projectRoot, ".local"),
        PIP_USER: "0",
        npm_config_prefix: path.join(projectRoot, ".npm-global"),
      };
      finalEnv = { ...process.env, ...wsEnv, ...(opts.env ?? {}) };
      await mkdir(path.join(projectRoot, "tmp"), { recursive: true });
    }

    const child = spawn(opts.command[0]!, opts.command.slice(1), {
      cwd,
      env: finalEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    const procState = { child, startedAtMs: startedAt, timedOut: false };
    this.runtimeExecActive.set(opts.executionId, procState);

    child.stdout?.on("data", (chunk: Buffer | string) => {
      const delta = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (!delta) return;
      stdout += delta;
      this.sendEvent("runtime.exec.outputDelta", {
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
      this.sendEvent("runtime.exec.outputDelta", {
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

    let timeout: NodeJS.Timeout | null = null;
    if (timeoutMs != null) {
      timeout = setTimeout(() => {
        procState.timedOut = true;
        try {
          child.kill("SIGKILL");
        } catch {
          // ignore
        }
      }, timeoutMs);
      timeout.unref();
    }

    const { exitCode } = await new Promise<{ exitCode: number | null }>((resolve) => {
      child.on("close", (code) => resolve({ exitCode: typeof code === "number" ? code : null }));
      child.on("error", () => resolve({ exitCode: null }));
    });

    if (timeout) clearTimeout(timeout);
    this.runtimeExecActive.delete(opts.executionId);

    const durationMs = Math.max(0, Date.now() - startedAt);
    const ok = !procState.timedOut && exitCode === 0;
    const error = procState.timedOut ? "Command timed out" : ok ? null : `Command exited with code ${String(exitCode ?? "unknown")}`;

    this.sendEvent("runtime.exec.completed", {
      projectId: opts.projectId,
      sessionId: opts.sessionId,
      threadId: opts.threadId,
      turnId: opts.turnId,
      itemId: opts.itemId,
      executionId: opts.executionId,
      ok,
      exitCode,
      durationMs,
      ...(error ? { error } : {}),
      ts: new Date().toISOString(),
    });

    return {
      ok,
      executionId: opts.executionId,
      exitCode,
      durationMs,
      stdout,
      stderr,
      ...(error ? { error } : {}),
      completedAt: new Date().toISOString(),
    };
  }

  private async runtimeExecCancel(executionId: string): Promise<boolean> {
    const active = this.runtimeExecActive.get(executionId);
    if (!active) return false;
    try {
      active.child.kill("SIGTERM");
    } catch {
      return false;
    }
    return true;
  }

  private async runtimeFsList(
    projectId: string,
    inputPath: string,
    opts: { recursive: boolean; includeHidden: boolean; limit: number }
  ) {
    const projectRoot = path.resolve(this.projectRoot(projectId));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const canonicalProjectRoot = await realpath(projectRoot).catch(() => projectRoot);
    const startPath = await this.resolveProjectPath(projectId, inputPath || ".");
    const maxEntries = Math.max(1, Math.min(20_000, Math.floor(opts.limit)));
    const recursive = Boolean(opts.recursive);
    const includeHidden = Boolean(opts.includeHidden);

    const queue: string[] = [];
    const entries: Array<{ path: string; type: "file" | "dir"; sizeBytes?: number; modifiedAt?: string }> = [];

    const enqueueDirectory = async (absDir: string) => {
      const list = await readdir(absDir, { withFileTypes: true });
      for (const dirent of list) {
        if (!includeHidden && dirent.name.startsWith(".")) continue;
        const absPath = path.join(absDir, dirent.name);

        let itemType: "file" | "dir";
        let itemSizeBytes: number | undefined;
        let itemModifiedAt: string | undefined;

        if (dirent.isSymbolicLink()) {
          const targetReal = await realpath(absPath);
          this.assertAllowedProjectPath(projectId, targetReal);
          const targetStat = await stat(targetReal);
          itemType = targetStat.isDirectory() ? "dir" : "file";
          itemSizeBytes = targetStat.isFile() ? targetStat.size : undefined;
          itemModifiedAt = targetStat.mtime.toISOString();
        } else if (dirent.isDirectory()) {
          const dirStat = await stat(absPath);
          itemType = "dir";
          itemModifiedAt = dirStat.mtime.toISOString();
        } else {
          const fileStat = await stat(absPath);
          itemType = "file";
          itemSizeBytes = fileStat.size;
          itemModifiedAt = fileStat.mtime.toISOString();
        }

        const relPath = path.relative(canonicalProjectRoot, absPath).replaceAll(path.sep, "/");
        if (!relPath || relPath.startsWith("..")) {
          continue;
        }
        entries.push({
          path: relPath,
          type: itemType,
          ...(itemSizeBytes != null ? { sizeBytes: itemSizeBytes } : {}),
          ...(itemModifiedAt ? { modifiedAt: itemModifiedAt } : {}),
        });

        if (entries.length >= maxEntries) return;
        if (itemType === "dir" && recursive) {
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

  private async runtimeFsStat(projectId: string, inputPath: string) {
    const abs = await this.resolveProjectPath(projectId, inputPath);
    const st = await stat(abs);
    return {
      path: abs,
      exists: true,
      type: st.isDirectory() ? "dir" : "file",
      sizeBytes: st.size,
      modifiedAt: st.mtime.toISOString(),
    };
  }

  private async runtimeFsRead(projectId: string, inputPath: string, offset: number, length: number, encoding: string) {
    const abs = await this.resolveProjectPath(projectId, inputPath);
    const fh = await open(abs, "r");
    try {
      const st = await fh.stat();
      const buf = Buffer.alloc(Math.max(0, length));
      const { bytesRead } = await fh.read(buf, 0, buf.length, offset);
      const sliced = buf.subarray(0, bytesRead);
      const data = encoding === "base64" ? sliced.toString("base64") : sliced.toString("utf8");
      return {
        path: abs,
        data,
        eof: offset + bytesRead >= st.size,
      };
    } finally {
      await fh.close();
    }
  }

  private async runtimeFsWrite(projectId: string, inputPath: string, data: string, encoding: string, permissionLevel: PermissionLevel) {
    const abs = await this.resolveProjectPath(projectId, inputPath, { forWrite: true });
    this.assertRuntimePathPolicy(projectId, abs, permissionLevel);
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

  private async runtimeFsDiff(projectId: string, paths: string[]) {
    const projectRoot = path.resolve(this.projectRoot(projectId));
    await this.ensureProjectWorkspaceDirs(projectRoot);
    const args = ["-C", projectRoot, "diff", "--no-color", "--"];
    if (paths.length > 0) {
      for (const entry of paths) {
        const abs = await this.resolveProjectPath(projectId, entry, { forWrite: true });
        args.push(path.relative(projectRoot, abs).replaceAll(path.sep, "/"));
      }
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
    sessionId: string;
    threadId: string;
    turnId: string;
    itemId: string;
    patchId: string;
    patch?: string;
    fileChanges?: Record<string, unknown>;
    permissionLevel: PermissionLevel;
  }) {
    const projectRoot = path.resolve(this.projectRoot(opts.projectId));
    await this.ensureProjectWorkspaceDirs(projectRoot);

    const patchText = opts.patch ?? renderPatchFromFileChanges(opts.fileChanges ?? {});
    if (!patchText.trim()) {
      throw new Error("Patch is empty");
    }

    const changedPaths = extractChangedPathsFromPatch(patchText);
    for (const relPath of changedPaths) {
      const abs = await this.resolveProjectPath(opts.projectId, relPath, { forWrite: true });
      this.assertRuntimePathPolicy(opts.projectId, abs, opts.permissionLevel);
    }

    const tmpDir = await mkdtemp(path.join(os.tmpdir(), "labos-patch-"));
    const patchPath = path.join(tmpDir, `${opts.patchId}.patch`);
    await writeFile(patchPath, patchText, "utf8");

    let applied = false;
    let error: string | null = null;
    try {
      await execFileAsync("git", ["-C", projectRoot, "apply", "--whitespace=nowarn", patchPath]);
      applied = true;
    } catch (err: any) {
      error = String(err?.stderr ?? err?.message ?? "git apply failed");
    } finally {
      await rm(tmpDir, { recursive: true, force: true }).catch(() => {});
    }

    const diffRes = await this.runtimeFsDiff(opts.projectId, changedPaths);
    const diffText = String(diffRes.diff ?? "") || patchText;

    if (changedPaths.length > 0) {
      for (const changedPath of changedPaths) {
        const perPathDiff = diffForSinglePath(diffText, changedPath);
        this.sendEvent("runtime.fs.changed", {
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
    }

    this.sendEvent("runtime.fs.patchCompleted", {
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

  private projectRoot(projectId: string) {
    if (!/^[A-Za-z0-9._-]+$/.test(projectId)) {
      throw new Error(`Invalid projectId: ${projectId}`);
    }
    return path.join(this.cfg.workspaceRoot, "projects", projectId);
  }

  private async ensureProjectWorkspaceDirs(projectRoot: string) {
    await mkdir(projectRoot, { recursive: true });
    await mkdir(path.join(projectRoot, "artifacts"), { recursive: true });
    await mkdir(path.join(projectRoot, "runs"), { recursive: true });
    await mkdir(path.join(projectRoot, "logs"), { recursive: true });
  }

  private async slurmSubmit(opts: {
    projectId: string;
    runId: string;
    job: any;
    staging: any;
    permissionLevel: PermissionLevel;
    policyOverride?: RuntimePolicy | null;
  }) {
    const policy = this.runtimePolicyFor(opts.policyOverride);
    const hasSlurm = await this.hasCommand("sbatch");
    if (!hasSlurm) {
      const fakeId = `SIM-${Date.now()}`;
      this.sendEvent("slurm.job.updated", { projectId: opts.projectId, runId: opts.runId, jobId: fakeId, state: "COMPLETED", ts: new Date().toISOString() });
      return { jobId: fakeId, submittedAt: new Date().toISOString() };
    }

    const user = await this.getSlurmUser();
    const runningCount = (await this.squeueJobIds({ user, state: "R" })).length;
    const pendingCount = (await this.squeueJobIds({ user, state: "PD" })).length;
    if (policy?.slurm?.maxConcurrent != null &&
        runningCount + pendingCount >= policy.slurm.maxConcurrent) {
      throw new Error(`Slurm concurrency limit exceeded (${policy.slurm.maxConcurrent})`);
    }

    const projectRoot = this.projectRoot(opts.projectId);
    const runRoot = path.join(projectRoot, "runs", opts.runId);
    const stagingRoot = path.join(runRoot, "staging");
    const artifactsDir = path.join(projectRoot, "artifacts");
    const logsDir = path.join(projectRoot, "logs");
    await mkdir(runRoot, { recursive: true });
    await mkdir(stagingRoot, { recursive: true });
    await mkdir(artifactsDir, { recursive: true });
    await mkdir(logsDir, { recursive: true });

    // Stage transient input files from Hub into this run's staging directory.
    const uploads = Array.isArray(opts.staging?.uploads) ? opts.staging.uploads : [];
    for (const u of uploads) {
      const uploadId = String(u.uploadId ?? "");
      const targetPathRaw = String(u.targetPath ?? "");
      if (!uploadId) continue;
      const normalizedTarget = sanitizeStagingRelativePath(targetPathRaw || path.basename(uploadId));
      if (!normalizedTarget) continue;
      const destination = path.resolve(stagingRoot, normalizedTarget);
      if (!destination.startsWith(stagingRoot + path.sep) && destination !== stagingRoot) {
        throw new Error(`Invalid staging target path: ${targetPathRaw}`);
      }
      await this.downloadUpload(opts.projectId, uploadId, destination);
    }

    const scriptPath = path.join(runRoot, "job.sbatch");
    const stdoutPathTemplate = path.join(projectRoot, String(opts.job?.outputs?.stdoutFile ?? "logs/slurm-%j.out"));
    const stderrPathTemplate = path.join(projectRoot, String(opts.job?.outputs?.stderrFile ?? "logs/slurm-%j.err"));

    const lines: string[] = [];
    lines.push("#!/bin/bash");
    lines.push(`#SBATCH --job-name=${shellEscape(String(opts.job?.name ?? "labos-run"))}`);
    const partition = normalizeOptionalString(opts.job?.resources?.partition) ?? this.hpcPrefs.partition;
    const account = normalizeOptionalString(opts.job?.resources?.account) ?? this.hpcPrefs.account;
    const qos = normalizeOptionalString(opts.job?.resources?.qos) ?? this.hpcPrefs.qos;
    if (partition) lines.push(`#SBATCH --partition=${shellEscape(partition)}`);
    if (account) lines.push(`#SBATCH --account=${shellEscape(account)}`);
    if (qos) lines.push(`#SBATCH --qos=${shellEscape(qos)}`);
    const requestedTimeMins = Number(opts.job?.resources?.timeLimitMinutes ?? this.cfg.defaults.timeLimitMinutes ?? 10);
    const timeMins = policy?.slurm?.maxTimeMinutes != null
      ? Math.min(policy.slurm.maxTimeMinutes, Math.max(1, Math.floor(requestedTimeMins)))
      : Math.max(1, Math.floor(requestedTimeMins));
    lines.push(`#SBATCH --time=${timeMins}`);
    const requestedCpus = Number(opts.job?.resources?.cpus ?? this.cfg.defaults.cpus ?? 1);
    const cpus = policy?.slurm?.maxCpus != null
      ? Math.min(policy.slurm.maxCpus, Math.max(1, Math.floor(requestedCpus)))
      : Math.max(1, Math.floor(requestedCpus));
    lines.push(`#SBATCH --cpus-per-task=${cpus}`);
    const requestedMemMb = Number(opts.job?.resources?.memMB ?? this.cfg.defaults.memMB ?? 512);
    const memMB = policy?.slurm?.maxMemMB != null
      ? Math.min(policy.slurm.maxMemMB, Math.max(1, Math.floor(requestedMemMb)))
      : Math.max(1, Math.floor(requestedMemMb));
    lines.push(`#SBATCH --mem=${memMB}M`);
    const requestedGpus = Number(opts.job?.resources?.gpus ?? this.cfg.defaults.gpus ?? 0);
    const gpus = policy?.slurm?.maxGpus != null
      ? Math.min(policy.slurm.maxGpus, Math.max(0, Math.floor(requestedGpus)))
      : Math.max(0, Math.floor(requestedGpus));
    if (gpus > 0) lines.push(`#SBATCH --gres=gpu:${Math.floor(gpus)}`);
    lines.push(`#SBATCH --output=${shellEscape(stdoutPathTemplate)}`);
    lines.push(`#SBATCH --error=${shellEscape(stderrPathTemplate)}`);
    lines.push(`#SBATCH --chdir=${shellEscape(path.join(projectRoot, String(opts.job?.workdir ?? `runs/${opts.runId}`)))}`);

    lines.push("set -euo pipefail");
    if (opts.job?.env && typeof opts.job.env === "object") {
      for (const [k, v] of Object.entries(opts.job.env)) {
        lines.push(`export ${k}=${shellEscape(String(v))}`);
      }
    }

    const cmd = Array.isArray(opts.job?.command) ? opts.job.command.map(String) : ["bash", "-lc", "echo missing command"];
    lines.push(cmd.map(shellEscape).join(" "));

    await mkdir(path.dirname(scriptPath), { recursive: true });
    await writeFileAtomic(scriptPath, lines.join("\n") + "\n");

    const { stdout } = await execFileAsync("sbatch", [scriptPath]);
    const match = stdout.match(/Submitted batch job (\\d+)/);
    const jobId = match ? match[1] : stdout.trim();
    const stdoutPath = expandSlurmPathTemplate(stdoutPathTemplate, jobId);
    const stderrPath = expandSlurmPathTemplate(stderrPathTemplate, jobId);

    this.sendEvent("slurm.job.updated", { projectId: opts.projectId, runId: opts.runId, jobId, state: "SUBMITTED", ts: new Date().toISOString() });

    // Fire-and-forget monitor
    void this.monitorJob({ projectId: opts.projectId, runId: opts.runId, jobId, stdoutPath, stderrPath });

    return { jobId, submittedAt: new Date().toISOString(), stdoutPath, stderrPath };
  }

  private async shellExec(opts: {
    projectId: string;
    runId: string;
    command: string[];
    cwd?: string;
    env?: Record<string, string>;
    timeoutMs?: number;
    permissionLevel: PermissionLevel;
  }) {
    const projectRoot = this.projectRoot(opts.projectId);
    const runRoot = path.join(projectRoot, "runs", opts.runId);
    const artifactsDir = path.join(projectRoot, "artifacts");
    const logsDir = path.join(projectRoot, "logs");
    const uploadsDir = path.join(projectRoot, "uploads");
    await mkdir(runRoot, { recursive: true });
    await mkdir(artifactsDir, { recursive: true });
    await mkdir(logsDir, { recursive: true });
    await mkdir(uploadsDir, { recursive: true });

    const resolvedCwd = resolveRuntimeCommandCwd({
      workspaceRoot: this.cfg.workspaceRoot,
      projectRoot,
      rawCwd: opts.cwd,
      fallbackCwd: runRoot,
    });

    if (opts.permissionLevel === "default") {
      this.assertAllowedProjectPath(opts.projectId, resolvedCwd);
    }

    const startedAt = Date.now();
    try {
      const { stdout, stderr } = await execFileAsync(opts.command[0]!, opts.command.slice(1), {
        cwd: resolvedCwd,
        env: { ...process.env, ...(opts.env ?? {}) },
        timeout: opts.timeoutMs ?? 10 * 60 * 1000,
        maxBuffer: 8 * 1024 * 1024,
      });

      const out = String(stdout ?? "");
      const err = String(stderr ?? "");
      if (out) this.sendEvent("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stdout", delta: out });
      if (err) this.sendEvent("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stderr", delta: err });

      const artifacts = await this.scanArtifacts(opts.projectId, "artifacts");
      this.sendEvent("artifacts.updated", { projectId: opts.projectId, artifacts });

      return {
        ok: true,
        exitCode: 0,
        startedAt: new Date(startedAt).toISOString(),
        completedAt: new Date().toISOString(),
        durationMs: Date.now() - startedAt,
        stdout: out,
        stderr: err,
        artifacts,
      };
    } catch (err: any) {
      const out = String(err?.stdout ?? "");
      const errText = String(err?.stderr ?? "");
      if (out) this.sendEvent("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stdout", delta: out });
      if (errText) this.sendEvent("runs.log.delta", { projectId: opts.projectId, runId: opts.runId, stream: "stderr", delta: errText });
      const code = err?.code;
      const codeText = typeof code === "number" || typeof code === "string" ? ` (exit ${String(code)})` : "";
      throw new Error(`shell.exec failed${codeText}: ${String(err?.message ?? "unknown error")}`);
    }
  }

  private async slurmStatus(jobId: string) {
    if (!jobId) return { state: "UNKNOWN", updatedAt: new Date().toISOString() };
    const hasSlurm = await this.hasCommand("squeue");
    if (!hasSlurm) return { state: "SIMULATED", updatedAt: new Date().toISOString() };

    try {
      const { stdout } = await execFileAsync("squeue", ["-j", jobId, "-h", "-o", "%T"]);
      const state = stdout.trim();
      if (state) return { state, updatedAt: new Date().toISOString() };
    } catch {
      // ignore
    }

    try {
      const { stdout } = await execFileAsync("sacct", ["-j", jobId, "-n", "-o", "State"]);
      const state = stdout.trim().split(/\s+/)[0] ?? "UNKNOWN";
      return { state, updatedAt: new Date().toISOString() };
    } catch {
      return { state: "UNKNOWN", updatedAt: new Date().toISOString() };
    }
  }

  private async slurmCancel(jobId: string) {
    const has = await this.hasCommand("scancel");
    if (!has) return;
    await execFileAsync("scancel", [jobId]);
  }

  private async monitorJob(opts: { projectId: string; runId: string; jobId: string; stdoutPath: string; stderrPath: string }) {
    let outOffset = 0;
    let errOffset = 0;
    while (true) {
      const status = await this.slurmStatus(opts.jobId);
      this.sendEvent("slurm.job.updated", { projectId: opts.projectId, runId: opts.runId, jobId: opts.jobId, state: status.state, ts: new Date().toISOString() });

      ({ nextOffset: outOffset } = await this.emitLogDelta(opts.projectId, opts.runId, "stdout", opts.stdoutPath, outOffset));
      ({ nextOffset: errOffset } = await this.emitLogDelta(opts.projectId, opts.runId, "stderr", opts.stderrPath, errOffset));

      if (isTerminalSlurmState(status.state)) {
        const artifacts = await this.scanArtifacts(opts.projectId, "artifacts");
        this.sendEvent("artifacts.updated", { projectId: opts.projectId, artifacts });
        return;
      }
      await sleep(1000);
    }
  }

  private async emitLogDelta(projectId: string, runId: string, stream: "stdout" | "stderr" | "system", absPath: string, offset: number) {
    try {
      const res = await this.fsReadRange(absPath, offset, 64 * 1024, "utf8");
      const delta = res.data ?? "";
      if (delta) {
        this.sendEvent("runs.log.delta", { projectId, runId, stream, delta });
      }
      const nextOffset = offset + Buffer.byteLength(delta, "utf8");
      return { nextOffset };
    } catch {
      return { nextOffset: offset };
    }
  }

  private async scanArtifacts(projectId: string, root: string) {
    const projectRoot = this.projectRoot(projectId);
    const dir = path.join(projectRoot, root);
    try {
      const items = await readdir(dir, { withFileTypes: true });
      const out: Array<{ path: string; sizeBytes: number; modifiedAt: string }> = [];
      for (const it of items) {
        if (it.isDirectory()) continue;
        const abs = path.join(dir, it.name);
        const st = await stat(abs);
        out.push({ path: `${root}/${it.name}`, sizeBytes: st.size, modifiedAt: st.mtime.toISOString() });
      }
      return out;
    } catch {
      return [];
    }
  }

  private async logsTail(absPath: string, sinceOffset: number) {
    const res = await this.fsReadRange(absPath, sinceOffset, 64 * 1024, "utf8");
    const data = res.data ?? "";
    return { data, nextOffset: sinceOffset + Buffer.byteLength(data, "utf8") };
  }

  private async hasCommand(bin: string) {
    try {
      await execFileAsync("which", [bin]);
      return true;
    } catch {
      return false;
    }
  }

  private hubHttpBase() {
    const u = new URL(this.cfg.hubUrl);
    if (u.protocol === "wss:") u.protocol = "https:";
    else if (u.protocol === "ws:") u.protocol = "http:";
    return u;
  }

  private async downloadUpload(projectId: string, uploadId: string, destAbsPath: string) {
    const base = this.hubHttpBase();
    const url = new URL(`/projects/${projectId}/uploads/${uploadId}`, base);
    await mkdir(path.dirname(destAbsPath), { recursive: true });

    const res = await fetch(url, { headers: { Authorization: `Bearer ${this.cfg.token}` } });
    if (!res.ok) throw new Error(`download failed: ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    await writeFileAtomic(destAbsPath, buf);
  }
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
      continue;
    }
  }

  return chunks.join("\n").trim() ? `${chunks.join("\n")}\n` : "";
}

function extractChangedPathsFromPatch(patchText: string): string[] {
  const out = new Set<string>();
  const lines = patchText.split(/\r?\n/);
  for (const line of lines) {
    if (line.startsWith("+++ b/")) {
      const p = line.slice("+++ b/".length).trim();
      if (p && p !== "/dev/null") out.add(p);
      continue;
    }
    if (line.startsWith("--- a/")) {
      const p = line.slice("--- a/".length).trim();
      if (p && p !== "/dev/null") out.add(p);
      continue;
    }
  }
  return Array.from(out);
}

function diffForSinglePath(fullDiff: string, filePath: string): string {
  if (!fullDiff.trim()) return "";
  const normalized = filePath.replaceAll("\\", "/");
  const sections = fullDiff.split(/^diff --git /m);
  const matches = sections.filter((section) => section.includes(` a/${normalized} `) || section.includes(` b/${normalized}`));
  if (matches.length === 0) return "";
  return matches.map((section) => (section.startsWith("diff --git ") ? section : `diff --git ${section}`)).join("\n");
}

function shellEscape(value: string) {
  if (value === "") return "''";
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function normalizeOptionalString(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const trimmed = v.trim();
  return trimmed ? trimmed : undefined;
}

export function resolveRuntimeCommandCwd(args: {
  workspaceRoot: string;
  projectRoot: string;
  rawCwd?: string | null;
  fallbackCwd: string;
}): string {
  const normalized = normalizeOptionalString(args.rawCwd ?? undefined);
  if (!normalized) {
    return path.resolve(args.fallbackCwd);
  }
  if (path.isAbsolute(normalized)) {
    return path.resolve(normalized);
  }
  if (normalized === "projects" || normalized.startsWith("projects/") || normalized.startsWith(`projects${path.sep}`)) {
    return path.resolve(args.workspaceRoot, normalized);
  }
  return path.resolve(args.projectRoot, normalized);
}

function normalizePositiveInt(raw: unknown, fallback: number): number {
  const parsed = typeof raw === "number" ? raw : Number(raw);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.floor(parsed);
  return normalized > 0 ? normalized : fallback;
}

function normalizePermissionLevel(v: unknown): PermissionLevel | null {
  const raw = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (raw === "default") return "default";
  if (raw === "full") return "full";
  return null;
}

function normalizeRuntimePolicy(raw: unknown): RuntimePolicy | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const obj = raw as Record<string, unknown>;

  const maybeExec = obj.exec && typeof obj.exec === "object" && !Array.isArray(obj.exec)
    ? (obj.exec as Record<string, unknown>)
    : null;
  const maybeSlurm = obj.slurm && typeof obj.slurm === "object" && !Array.isArray(obj.slurm)
    ? (obj.slurm as Record<string, unknown>)
    : null;

  const exec: NonNullable<RuntimePolicy["exec"]> = {};
  if (maybeExec) {
    if (Number.isFinite(Number(maybeExec.maxTimeoutMs))) exec.maxTimeoutMs = Math.max(1, Math.floor(Number(maybeExec.maxTimeoutMs)));
    if (Number.isFinite(Number(maybeExec.maxConcurrent))) exec.maxConcurrent = Math.max(1, Math.floor(Number(maybeExec.maxConcurrent)));
  }

  const slurm: NonNullable<RuntimePolicy["slurm"]> = {};
  if (maybeSlurm) {
    if (Number.isFinite(Number(maybeSlurm.maxTimeMinutes))) slurm.maxTimeMinutes = Math.max(1, Math.floor(Number(maybeSlurm.maxTimeMinutes)));
    if (Number.isFinite(Number(maybeSlurm.maxCpus))) slurm.maxCpus = Math.max(1, Math.floor(Number(maybeSlurm.maxCpus)));
    if (Number.isFinite(Number(maybeSlurm.maxMemMB))) slurm.maxMemMB = Math.max(1, Math.floor(Number(maybeSlurm.maxMemMB)));
    if (Number.isFinite(Number(maybeSlurm.maxGpus))) slurm.maxGpus = Math.max(0, Math.floor(Number(maybeSlurm.maxGpus)));
    if (Number.isFinite(Number(maybeSlurm.maxConcurrent))) slurm.maxConcurrent = Math.max(1, Math.floor(Number(maybeSlurm.maxConcurrent)));
  }

  const hasExec = Object.keys(exec).length > 0;
  const hasSlurm = Object.keys(slurm).length > 0;
  if (!hasExec && !hasSlurm) return null;
  return {
    ...(hasExec ? { exec } : {}),
    ...(hasSlurm ? { slurm } : {}),
  };
}

function normalizeSandboxMode(raw: unknown): "workspace-write" | "danger-full-access" | "read-only" {
  const v = typeof raw === "string" ? raw.trim().toLowerCase() : "";
  if (v === "danger-full-access") return "danger-full-access";
  if (v === "read-only") return "read-only";
  return "workspace-write";
}

function expandSlurmPathTemplate(template: string, jobId: string) {
  return template.replace(/%[jJ]/g, jobId);
}

function firstNonEmptyLine(text: string | null): string | null {
  if (!text) return null;
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed) return trimmed;
  }
  return null;
}

function isEmptyTres(t: HpcTres) {
  return t.cpu == null && t.memMB == null && t.gpus == null;
}

function parseTresString(raw: string): HpcTres {
  const out: HpcTres = {};
  const trimmed = raw.trim();
  if (!trimmed) return out;
  if (["N/A", "NONE", "UNLIMITED"].includes(trimmed.toUpperCase())) return out;

  for (const part of trimmed.split(",")) {
    const p = part.trim();
    if (!p) continue;
    const idx = p.indexOf("=");
    if (idx === -1) continue;
    const key = p.slice(0, idx).trim();
    const value = p.slice(idx + 1).trim();
    if (!key || !value) continue;

    if (key === "cpu") {
      const n = Number.parseInt(value, 10);
      if (Number.isFinite(n) && n > 0) out.cpu = addOptional(out.cpu, n);
      continue;
    }
    if (key === "mem") {
      const mb = parseSlurmSizeToMB(value);
      if (mb != null) out.memMB = addOptional(out.memMB, mb);
      continue;
    }
    if (key === "gres/gpu" || key === "gpu" || key.startsWith("gres/gpu:")) {
      const m = value.match(/\d+/);
      const n = m ? Number.parseInt(m[0], 10) : NaN;
      if (Number.isFinite(n) && n > 0) out.gpus = addOptional(out.gpus, n);
      continue;
    }
  }
  return out;
}

function parseScontrolJobLineTres(line: string): HpcTres {
  const tokens = line.trim().split(/\s+/);
  const tresToken = tokens.find(
    (t) => t.startsWith("TRES=") || t.startsWith("Tres=") || t.startsWith("TRES_ALLOC=") || t.startsWith("TRES_ALLOCATED=")
  );
  if (tresToken) {
    const idx = tresToken.indexOf("=");
    const raw = idx === -1 ? "" : tresToken.slice(idx + 1);
    return parseTresString(raw);
  }

  const out: HpcTres = {};
  for (const t of tokens) {
    if (t.startsWith("NumCPUs=")) {
      const v = t.slice("NumCPUs=".length);
      const n = Number.parseInt(v, 10);
      if (Number.isFinite(n) && n > 0) out.cpu = addOptional(out.cpu, n);
      continue;
    }

    if (t.startsWith("MinMemoryNode=") || t.startsWith("MinMemoryCPU=")) {
      const idx = t.indexOf("=");
      const v = idx === -1 ? "" : t.slice(idx + 1);
      const mb = parseSlurmSizeToMB(v);
      if (mb != null) out.memMB = addOptional(out.memMB, mb);
      continue;
    }

    if (t.startsWith("Gres=")) {
      const v = t.slice("Gres=".length);
      let gpus = 0;
      for (const part of v.split(",")) {
        const p = part.trim();
        if (!p.startsWith("gpu:")) continue;
        const segs = p.split(":").filter(Boolean);
        const last = segs[segs.length - 1] ?? "";
        const n = Number.parseInt(last, 10);
        if (Number.isFinite(n) && n > 0) gpus += n;
      }
      if (gpus > 0) out.gpus = addOptional(out.gpus, gpus);
    }
  }
  return out;
}

function parseSlurmSizeToMB(value: string): number | undefined {
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed === "0") return undefined;
  const m = trimmed.match(/^(\d+(?:\.\d+)?)([KMGTP])?/i);
  if (!m) return undefined;
  const n = Number(m[1]);
  if (!Number.isFinite(n) || n <= 0) return undefined;
  const unit = (m[2] ?? "").toUpperCase();
  const mb =
    unit === "K"
      ? n / 1024
      : unit === "G"
        ? n * 1024
        : unit === "T"
          ? n * 1024 * 1024
          : unit === "P"
            ? n * 1024 * 1024 * 1024
            : n;
  return Math.floor(mb);
}

function addOptional(a: number | undefined, b: number | undefined) {
  if (a == null && b == null) return undefined;
  return (a ?? 0) + (b ?? 0);
}

function minTres(a: HpcTres | null, b: HpcTres | null): HpcTres | null {
  if (!a && !b) return null;
  if (!a) return b;
  if (!b) return a;
  return {
    cpu: minOptional(a.cpu, b.cpu),
    memMB: minOptional(a.memMB, b.memMB),
    gpus: minOptional(a.gpus, b.gpus),
  };
}

function minOptional(a: number | undefined, b: number | undefined) {
  if (a == null) return b;
  if (b == null) return a;
  return Math.min(a, b);
}

function subtractTres(limit: HpcTres, inUse: HpcTres): HpcTres {
  return {
    cpu: subtractOptional(limit.cpu, inUse.cpu),
    memMB: subtractOptional(limit.memMB, inUse.memMB),
    gpus: subtractOptional(limit.gpus, inUse.gpus),
  };
}

function subtractOptional(limit: number | undefined, used: number | undefined) {
  if (limit == null || used == null) return undefined;
  return Math.max(0, limit - used);
}

function addTres(a: HpcTres, b: HpcTres): HpcTres {
  return {
    cpu: addOptional(a.cpu, b.cpu),
    memMB: addOptional(a.memMB, b.memMB),
    gpus: addOptional(a.gpus, b.gpus),
  };
}

function isTerminalSlurmState(state: string) {
  const s = state.toUpperCase();
  return s.includes("COMPLETED") || s.includes("FAILED") || s.includes("CANCELLED") || s.includes("TIMEOUT");
}

function sanitizeStagingRelativePath(raw: string): string | null {
  const trimmed = String(raw ?? "").trim().replaceAll("\\", "/");
  if (!trimmed) return null;
  if (trimmed.startsWith("/") || trimmed.startsWith("../") || trimmed.includes("/../") || trimmed === "..") {
    return null;
  }
  const normalized = path.posix.normalize(trimmed);
  if (normalized.startsWith("../") || normalized === ".." || normalized === ".") {
    return null;
  }
  return normalized;
}

async function writeFileAtomic(filePath: string, content: string | Buffer) {
  const tmp = `${filePath}.tmp-${Date.now()}`;
  await mkdir(path.dirname(filePath), { recursive: true });
  await import("node:fs/promises").then((fs) => fs.writeFile(tmp, content));
  await import("node:fs/promises").then((fs) => fs.rename(tmp, filePath));
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
