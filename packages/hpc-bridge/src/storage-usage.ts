import { execFile } from "node:child_process";
import process from "node:process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type StorageUsage = {
  totalBytes: number;
  usedBytes: number;
  availableBytes: number;
  usedPercent: number;
};

export function parseDfPkOutput(raw: string): StorageUsage | null {
  const lines = String(raw ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length < 2) return null;

  const fields = lines[lines.length - 1].split(/\s+/).filter(Boolean);
  if (fields.length < 5) return null;

  const totalBlocks = Number(fields[1]);
  const usedBlocks = Number(fields[2]);
  const availableBlocks = Number(fields[3]);

  if (!Number.isFinite(totalBlocks) || totalBlocks <= 0) return null;
  if (!Number.isFinite(usedBlocks) || usedBlocks < 0) return null;
  if (!Number.isFinite(availableBlocks) || availableBlocks < 0) return null;

  const usedPercent = parseCapacityPercent(fields[4], usedBlocks, totalBlocks);
  const bytesPerBlock = 1024;

  return {
    totalBytes: Math.round(totalBlocks * bytesPerBlock),
    usedBytes: Math.round(usedBlocks * bytesPerBlock),
    availableBytes: Math.round(availableBlocks * bytesPerBlock),
    usedPercent,
  };
}

export async function collectStorageUsage(pathToInspect: string): Promise<StorageUsage | null> {
  const trimmed = String(pathToInspect ?? "").trim();
  if (!trimmed) return null;

  try {
    const { stdout } = await execFileAsync("df", ["-Pk", trimmed], {
      env: { ...process.env, LC_ALL: "C" },
    });
    return parseDfPkOutput(String(stdout ?? ""));
  } catch {
    return null;
  }
}

function parseCapacityPercent(raw: string, usedBlocks: number, totalBlocks: number): number {
  const match = String(raw ?? "").match(/(\d+(?:\.\d+)?)%/);
  if (match) {
    const parsed = Number(match[1]);
    if (Number.isFinite(parsed)) {
      return Math.min(Math.max(parsed, 0), 100);
    }
  }

  const ratio = totalBlocks > 0 ? (usedBlocks / totalBlocks) * 100 : 0;
  return Math.min(Math.max(ratio, 0), 100);
}
