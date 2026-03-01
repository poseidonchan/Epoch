import { spawn } from "node:child_process";
import { openSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

export type BridgeDaemonInfo = {
  pid: number;
  startedAt: string;
  logPath: string;
};

export function bridgePidPath(stateDir: string) {
  return path.join(stateDir, "bridge.pid");
}

export function bridgeLogPath(stateDir: string) {
  return path.join(stateDir, "bridge.log");
}

export async function readBridgeDaemonInfo(stateDir: string): Promise<BridgeDaemonInfo | null> {
  const pidPath = bridgePidPath(stateDir);
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
          logPath: parseOptionalNonEmptyString(data.logPath) ?? bridgeLogPath(stateDir),
        };
      }
    } catch {
      // fall through to plain pid format
    }
    const pid = parsePid(Number(trimmed));
    if (pid == null) return null;
    return {
      pid,
      startedAt: new Date().toISOString(),
      logPath: bridgeLogPath(stateDir),
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
  await new Promise((resolve) => setTimeout(resolve, ms));
}

export async function stopBridgeDaemon(stateDir: string, opts?: { timeoutMs?: number }): Promise<{ stopped: boolean; pid?: number }> {
  const info = await readBridgeDaemonInfo(stateDir);
  if (!info) return { stopped: false };

  const pidPath = bridgePidPath(stateDir);
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

  const timeoutMs = opts?.timeoutMs ?? 5_000;
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

export async function startBridgeDaemon(opts: {
  stateDir: string;
  cliPath: string;
  nodePath: string;
  env: NodeJS.ProcessEnv;
  cwd: string;
}): Promise<BridgeDaemonInfo> {
  await mkdir(opts.stateDir, { recursive: true });

  const logPath = bridgeLogPath(opts.stateDir);
  const out = openSync(logPath, "a", 0o600);
  const err = out;

  const child = spawn(opts.nodePath, [opts.cliPath, "start", "--foreground"], {
    cwd: opts.cwd,
    env: opts.env,
    detached: true,
    stdio: ["ignore", out, err],
  });
  child.unref();

  const info: BridgeDaemonInfo = {
    pid: child.pid ?? -1,
    startedAt: new Date().toISOString(),
    logPath,
  };

  await writeFile(bridgePidPath(opts.stateDir), JSON.stringify(info, null, 2) + "\n", {
    encoding: "utf8",
    mode: 0o600,
  });
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
