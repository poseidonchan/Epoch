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
      if (obj && typeof obj.pid === "number") return obj as HubDaemonInfo;
    } catch {
      // fall back
    }
    const pid = Number(trimmed);
    if (!Number.isFinite(pid)) return null;
    return { pid, startedAt: new Date().toISOString(), host: "0.0.0.0", port: 8787, logPath: hubLogPath(stateDir) };
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
}): Promise<HubDaemonInfo> {
  await mkdir(opts.stateDir, { recursive: true });

  const logPath = hubLogPath(opts.stateDir);
  const out = openSync(logPath, "a", 0o600);
  const err = out;

  const child = spawn(opts.nodePath, [opts.cliPath, "start", "--foreground"], {
    cwd: opts.cwd,
    env: opts.env,
    detached: true,
    stdio: ["ignore", out, err],
  });

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
