import os from "node:os";
import path from "node:path";

export function normalizeWorkspacePath(rawPath: unknown): string | null {
  if (typeof rawPath !== "string") {
    return null;
  }
  const trimmed = rawPath.trim();
  if (!trimmed) {
    return null;
  }

  // Repair legacy values produced by path.resolve(cwd, "~/...").
  const repaired = repairEmbeddedTildePath(trimmed) ?? trimmed;
  if (repaired === "~") {
    return os.homedir();
  }
  if (repaired.startsWith("~/") || repaired.startsWith("~\\")) {
    return path.resolve(os.homedir(), repaired.slice(2));
  }
  if (!path.isAbsolute(repaired)) {
    return null;
  }
  return path.resolve(repaired);
}

export function requireWorkspacePath(rawPath: unknown, fieldName = "workspacePath"): string {
  const normalized = normalizeWorkspacePath(rawPath);
  if (normalized) {
    return normalized;
  }
  throw new Error(`${fieldName} must be an absolute path or start with "~/"`);
}

function repairEmbeddedTildePath(rawPath: string): string | null {
  const normalized = rawPath.replaceAll("\\", "/");
  const embeddedIndex = normalized.indexOf("/~/");
  if (embeddedIndex >= 0) {
    return normalized.slice(embeddedIndex + 1);
  }
  if (normalized.endsWith("/~")) {
    return "~";
  }
  return null;
}
