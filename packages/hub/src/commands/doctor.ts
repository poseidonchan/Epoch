import process from "node:process";
import path from "node:path";
import { stat } from "node:fs/promises";

import { getStateDir, loadOrCreateHubConfig } from "../config.js";
import { connectDb, runMigrations, type DbPool } from "../db/db.js";
import { resolveHubModel } from "../model.js";
import { CodexEngineRegistry } from "../codex_rpc/engine_registry.js";

export async function doctorCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  const engines = new CodexEngineRegistry({ config, stateDir });
  const defaultEngine = engines.defaultEngineName();

  const dbPath = process.env.EPOCH_DB_PATH ?? path.join(stateDir, "epoch.sqlite");
  const modelResolved = resolveHubModel(config);
  console.log(`State dir: ${stateDir}`);
  console.log(`Config: ${config ? "present" : "missing (run epoch-hub init)"}`);
  console.log(`DB: ${dbPath}`);
  console.log(`Default engine: ${defaultEngine}`);
  if (modelResolved.ok) {
    console.log(`Model: ${modelResolved.ref}${modelResolved.hasApiKey ? "" : " (no credentials detected; run epoch-hub config)"}`);
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

    const envWorkspaceRoot = normalizeNonEmptyString(process.env.EPOCH_HPC_WORKSPACE_ROOT);
    const nodeWorkspaceRoot = await resolveLatestNodeWorkspaceRoot(pool);
    const resolvedWorkspaceRoot = envWorkspaceRoot ?? nodeWorkspaceRoot;
    if (envWorkspaceRoot) {
      console.log(`Workspace root: ${envWorkspaceRoot} (EPOCH_HPC_WORKSPACE_ROOT)`);
    } else if (nodeWorkspaceRoot) {
      console.log(`Workspace root: ${nodeWorkspaceRoot} (latest node permissions)`);
    } else {
      console.warn(
        "WARN: Workspace root is unavailable. Set EPOCH_HPC_WORKSPACE_ROOT or connect an HPC node that reports permissions.workspaceRoot."
      );
    }

    if (defaultEngine === "codex-app-server" && resolvedWorkspaceRoot) {
      const existsOnHub = await stat(resolvedWorkspaceRoot).then(() => true).catch(() => false);
      if (!existsOnHub) {
        console.warn(
          "WARN: Default engine is codex-app-server but the workspace root is not present on this machine. " +
            "If Hub and HPC do not share a filesystem, local execution will fail with ENOENT. " +
            "Use the epoch-hpc engine so exec/applyPatch run via the HPC bridge."
        );
      }
    }
  } finally {
    await engines.close();
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
