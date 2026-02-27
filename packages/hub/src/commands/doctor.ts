import process from "node:process";
import path from "node:path";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations, type DbPool } from "../db/db.js";
import { resolveHubModel } from "../model.js";

export async function doctorCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });

  const dbPath = process.env.LABOS_DB_PATH ?? path.join(stateDir, "labos.sqlite");
  const modelResolved = resolveHubModel(config);
  console.log(`State dir: ${stateDir}`);
  console.log(`Config: ${config ? "present" : "missing (run labos-hub init)"}`);
  console.log(`DB: ${dbPath}`);
  if (modelResolved.ok) {
    console.log(`Model: ${modelResolved.ref}${modelResolved.hasApiKey ? "" : " (no credentials detected; run labos-hub config)"}`);
  } else {
    console.log(`Model: ${modelResolved.ref ?? "missing"} (${modelResolved.message})`);
  }

  if (!config) {
    process.exitCode = 1;
    return;
  }

  const pool = await connectDb(dbPath);
  try {
    await runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    console.log("DB migrations: ok");

    const envWorkspaceRoot = normalizeNonEmptyString(process.env.LABOS_HPC_WORKSPACE_ROOT);
    const nodeWorkspaceRoot = await resolveLatestNodeWorkspaceRoot(pool);
    if (envWorkspaceRoot) {
      console.log(`Workspace root: ${envWorkspaceRoot} (LABOS_HPC_WORKSPACE_ROOT)`);
    } else if (nodeWorkspaceRoot) {
      console.log(`Workspace root: ${nodeWorkspaceRoot} (latest node permissions)`);
    } else {
      console.warn(
        "WARN: Workspace root is unavailable. Set LABOS_HPC_WORKSPACE_ROOT or connect an HPC node that reports permissions.workspaceRoot."
      );
    }
  } finally {
    await pool.end();
  }
}

async function resolveLatestNodeWorkspaceRoot(pool: DbPool): Promise<string | null> {
  const result = await pool.query<{ permissions?: unknown }>(
    `SELECT permissions
       FROM nodes
       ORDER BY last_seen_at DESC, created_at DESC
       LIMIT 20`
  );

  for (const row of result.rows) {
    const parsed = parseJsonObject(row?.permissions);
    const workspaceRoot = normalizeNonEmptyString(parsed?.workspaceRoot);
    if (workspaceRoot) return workspaceRoot;
  }
  return null;
}

function parseJsonObject(raw: unknown): Record<string, unknown> | null {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}
