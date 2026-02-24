import path from "node:path";

// UUIDs are stored as TEXT in SQLite. Clients may send uppercase UUID strings
// (e.g., Swift's UUID.uuidString). Normalize IDs to lowercase at the boundary so
// lookups work reliably.
export function normalizeId(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

export function sanitizeFilename(name: string) {
  const base = path.posix.basename(name);
  return base.replace(/[^a-zA-Z0-9._-]+/g, "_");
}

export function normalizeRelativePath(p: string): string | null {
  if (!p) return null;
  if (p.includes("\0")) return null;
  if (path.isAbsolute(p)) return null;
  const norm = path.posix.normalize(p).replace(/^(\.\.(\/|\\|$))+/, "");
  if (norm.startsWith("..")) return null;
  return norm;
}

export function normalizeOptionalString(v: unknown): string | undefined {
  if (typeof v !== "string") return undefined;
  const trimmed = v.trim();
  return trimmed ? trimmed : undefined;
}

export function normalizePermissionLevel(v: unknown): "default" | "full" | null {
  const raw = typeof v === "string" ? v.trim().toLowerCase() : "";
  if (raw === "default") return "default";
  if (raw === "full") return "full";
  return null;
}
