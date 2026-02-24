import { createHmac } from "node:crypto";
import { mkdir, readdir, stat, open } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

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

export class BridgeService {
  private ws: WebSocket | null = null;
  private seq = 0;
  private pending = new Map<string, PendingRequest>();

  private hpcPrefs: HpcPrefs = {};
  private heartbeatTimer: NodeJS.Timeout | null = null;
  private heartbeatInFlight = false;
  private slurmUser: string | null = null;
  private limitCache: { key: string; fetchedAt: number; limit: HpcTres | null } = { key: "", fetchedAt: 0, limit: null };

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
    this.heartbeatTimer = setInterval(tick, 5_000);
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
        case "slurm.submit": {
          const projectId = String(params.projectId ?? "");
          const runId = String(params.runId ?? "");
          const job = params.job ?? {};
          const staging = params.staging ?? { uploads: [] };
          const permissionLevel = normalizePermissionLevel(params.permissionLevel) ?? "default";
          const result = await this.slurmSubmit({ projectId, runId, job, staging, permissionLevel });
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

  private projectRoot(projectId: string) {
    return path.join(this.cfg.workspaceRoot, "projects", projectId);
  }

  private async ensureProjectWorkspaceDirs(projectRoot: string) {
    await mkdir(projectRoot, { recursive: true });
    await mkdir(path.join(projectRoot, "uploads"), { recursive: true });
    await mkdir(path.join(projectRoot, "artifacts"), { recursive: true });
    await mkdir(path.join(projectRoot, "runs"), { recursive: true });
    await mkdir(path.join(projectRoot, "logs"), { recursive: true });
  }

  private async slurmSubmit(opts: { projectId: string; runId: string; job: any; staging: any; permissionLevel: PermissionLevel }) {
    const hasSlurm = await this.hasCommand("sbatch");
    if (!hasSlurm) {
      const fakeId = `SIM-${Date.now()}`;
      this.sendEvent("slurm.job.updated", { projectId: opts.projectId, runId: opts.runId, jobId: fakeId, state: "COMPLETED", ts: new Date().toISOString() });
      return { jobId: fakeId, submittedAt: new Date().toISOString() };
    }

    const projectRoot = this.projectRoot(opts.projectId);
    const runRoot = path.join(projectRoot, "runs", opts.runId);
    const artifactsDir = path.join(projectRoot, "artifacts");
    const logsDir = path.join(projectRoot, "logs");
    const uploadsDir = path.join(projectRoot, "uploads");
    await mkdir(runRoot, { recursive: true });
    await mkdir(artifactsDir, { recursive: true });
    await mkdir(logsDir, { recursive: true });
    await mkdir(uploadsDir, { recursive: true });

    // Stage uploads from Hub
    const uploads = Array.isArray(opts.staging?.uploads) ? opts.staging.uploads : [];
    for (const u of uploads) {
      const uploadId = String(u.uploadId ?? "");
      const targetPath = String(u.targetPath ?? "");
      if (!uploadId || !targetPath) continue;
      await this.downloadUpload(opts.projectId, uploadId, path.join(projectRoot, targetPath));
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
    const timeMins = Number(opts.job?.resources?.timeLimitMinutes ?? this.cfg.defaults.timeLimitMinutes ?? 10);
    lines.push(`#SBATCH --time=${Math.max(1, Math.floor(timeMins))}`);
    const cpus = Number(opts.job?.resources?.cpus ?? this.cfg.defaults.cpus ?? 1);
    lines.push(`#SBATCH --cpus-per-task=${Math.max(1, Math.floor(cpus))}`);
    const memMB = Number(opts.job?.resources?.memMB ?? this.cfg.defaults.memMB ?? 512);
    lines.push(`#SBATCH --mem=${Math.max(1, Math.floor(memMB))}M`);
    const gpus = Number(opts.job?.resources?.gpus ?? this.cfg.defaults.gpus ?? 0);
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

    const resolvedCwd = (() => {
      const raw = normalizeOptionalString(opts.cwd);
      if (!raw) return runRoot;
      if (path.isAbsolute(raw)) return raw;
      if (raw.startsWith(`projects${path.sep}`) || raw === "projects" || raw.startsWith("projects/")) {
        return path.resolve(this.cfg.workspaceRoot, raw);
      }
      return path.resolve(projectRoot, raw);
    })();

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

function shellEscape(value: string) {
  if (value === "") return "''";
  return `'${value.replace(/'/g, `'\"'\"'`)}'`;
}

function normalizeOptionalString(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const trimmed = v.trim();
  return trimmed ? trimmed : undefined;
}

function normalizePermissionLevel(v: unknown): PermissionLevel | null {
  const raw = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (raw === "default") return "default";
  if (raw === "full") return "full";
  return null;
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

async function writeFileAtomic(filePath: string, content: string | Buffer) {
  const tmp = `${filePath}.tmp-${Date.now()}`;
  await mkdir(path.dirname(filePath), { recursive: true });
  await import("node:fs/promises").then((fs) => fs.writeFile(tmp, content));
  await import("node:fs/promises").then((fs) => fs.rename(tmp, filePath));
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
