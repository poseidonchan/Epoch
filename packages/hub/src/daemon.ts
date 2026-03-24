import { spawn } from "node:child_process";
import { openSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

export type HubDaemonInfo = {
  pid: number;
  startedAt: string;
  host: string;
  port: number;
  logPath: string;
};

export function hubPidPath(stateDir: string) {
  return path.join(stateDir, "hub.pid");
}

export function hubLogPath(stateDir: string) {
  return path.join(stateDir, "hub.log");
}

export async function readHubDaemonInfo(stateDir: string): Promise<HubDaemonInfo | null> {
  const pidPath = hubPidPath(stateDir);
  try {
    const raw = await readFile(pidPath, "utf8");
    const trimmed = raw.trim();
    if (!trimmed) return null;
    try {
      const obj = JSON.parse(trimmed);
      if (obj && typeof obj === "object" && !Array.isArray(obj)) {
        const data = obj as Record<string, unknown>;
        const pid = parsePid(data.pid);
        if (pid == null) return null;
        return {
          pid,
          startedAt: parseOptionalNonEmptyString(data.startedAt) ?? new Date().toISOString(),
          host: parseOptionalNonEmptyString(data.host) ?? "0.0.0.0",
          port: parsePort(data.port) ?? 8787,
          logPath: parseOptionalNonEmptyString(data.logPath) ?? hubLogPath(stateDir),
        };
      }
    } catch {
      // fall back
    }
    const pid = parsePid(Number(trimmed));
    if (pid == null) return null;
    return {
      pid,
      startedAt: new Date().toISOString(),
      host: "0.0.0.0",
      port: 8787,
      logPath: hubLogPath(stateDir),
    };
  } catch {
    return null;
  }
}

export function isProcessRunning(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function sleep(ms: number) {
  await new Promise((r) => setTimeout(r, ms));
}

export async function stopHubDaemon(stateDir: string, opts?: { timeoutMs?: number }): Promise<{ stopped: boolean; pid?: number }> {
  const info = await readHubDaemonInfo(stateDir);
  if (!info) return { stopped: false };

  const pidPath = hubPidPath(stateDir);
  const pid = info.pid;
  if (!Number.isFinite(pid) || pid <= 1) {
    await rm(pidPath, { force: true }).catch(() => {});
    return { stopped: false };
  }

  if (!isProcessRunning(pid)) {
    await rm(pidPath, { force: true }).catch(() => {});
    return { stopped: false, pid };
  }

  try {
    process.kill(pid, "SIGTERM");
  } catch {
    // ignore
  }

  const timeoutMs = opts?.timeoutMs ?? 5000;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isProcessRunning(pid)) {
      await rm(pidPath, { force: true }).catch(() => {});
      return { stopped: true, pid };
    }
    await sleep(100);
  }

  try {
    process.kill(pid, "SIGKILL");
  } catch {
    // ignore
  }

  for (let i = 0; i < 25; i += 1) {
    if (!isProcessRunning(pid)) break;
    await sleep(100);
  }

  await rm(pidPath, { force: true }).catch(() => {});
  return { stopped: true, pid };
}

export async function startHubDaemon(opts: {
  stateDir: string;
  cliPath: string;
  nodePath: string;
  host: string;
  port: number;
  env: NodeJS.ProcessEnv;
  cwd: string;
  stdinPayload?: string | null;
  extraArgs?: string[];
}): Promise<HubDaemonInfo> {
  await mkdir(opts.stateDir, { recursive: true });

  const logPath = hubLogPath(opts.stateDir);
  const out = openSync(logPath, "a", 0o600);
  const err = out;
  const extraArgs = Array.isArray(opts.extraArgs) ? opts.extraArgs : [];
  const needsStdin = typeof opts.stdinPayload === "string" && opts.stdinPayload.length > 0;

  const child = spawn(opts.nodePath, [opts.cliPath, "start", "--foreground", ...extraArgs], {
    cwd: opts.cwd,
    env: opts.env,
    detached: true,
    stdio: [needsStdin ? "pipe" : "ignore", out, err],
  });

  if (needsStdin && child.stdin) {
    child.stdin.end(opts.stdinPayload);
  }
  child.unref();

  const info: HubDaemonInfo = {
    pid: child.pid ?? -1,
    startedAt: new Date().toISOString(),
    host: opts.host,
    port: opts.port,
    logPath,
  };

  await writeFile(hubPidPath(opts.stateDir), JSON.stringify(info, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  return info;
}

function parseOptionalNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function parsePid(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const integer = Math.floor(value);
  return integer > 1 ? integer : null;
}

function parsePort(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const integer = Math.floor(value);
  if (integer < 1 || integer > 65535) return null;
  return integer;
}
