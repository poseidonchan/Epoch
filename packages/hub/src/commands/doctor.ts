import process from "node:process";
import path from "node:path";
import { stat } from "node:fs/promises";

import { getStateDir, loadOrCreateHubConfig, resolveConfiguredWorkspaceRoot } from "../config.js";
import { connectDb, runMigrations } from "../db/db.js";
import { resolveHubModel } from "../model.js";
import { readPushKeyStatus } from "../push_secrets.js";
import { resolvePairingWSURL } from "./pair_qr.js";
import { CodexEngineRegistry } from "../codex_rpc/engine_registry.js";

export async function doctorCommand(_argv: string[]) {
  const stateDir = getStateDir();
  const config = await loadOrCreateHubConfig({ stateDir, allowCreate: false });
  const engines = new CodexEngineRegistry({ config, stateDir });
  const defaultEngine = engines.defaultEngineName();
  const pushKeyStatus = config ? await readPushKeyStatus({ stateDir, config }) : null;

  const dbPath = process.env.EPOCH_DB_PATH ?? path.join(stateDir, "epoch.sqlite");
  const modelResolved = resolveHubModel(config);
  console.log(`State dir: ${stateDir}`);
  console.log(`Config: ${config ? "present" : "missing (run epoch init)"}`);
  console.log(`DB: ${dbPath}`);
  console.log(`Default engine: ${defaultEngine}`);
  console.log(`Display name: ${config?.displayName ?? "not configured"}`);
  console.log(`Background push: ${config?.pushEnabled === true ? "enabled" : "disabled"}`);
  console.log(`Push topic: ${config?.push?.bundleId ?? "not configured"}`);
  console.log(`Encrypted APNs key: ${pushKeyStatus?.exists ? "present" : "missing"}`);
  console.log(`Encrypted key permissions: ${pushKeyStatus?.privatePermissions ? "0600" : "not private"}`);
  if (modelResolved.ok) {
    console.log(`Model: ${modelResolved.ref}${modelResolved.hasApiKey ? "" : " (no credentials detected; run epoch config)"}`);
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

    const resolvedWorkspaceRoot = resolveConfiguredWorkspaceRoot({ stateDir, config, env: process.env });
    const workspaceRootSource = normalizeNonEmptyString(process.env.EPOCH_WORKSPACE_ROOT)
      ? "EPOCH_WORKSPACE_ROOT"
      : normalizeNonEmptyString(process.env.EPOCH_HPC_WORKSPACE_ROOT)
        ? "EPOCH_HPC_WORKSPACE_ROOT"
        : normalizeNonEmptyString(config?.workspaceRoot)
          ? "config.json"
          : "default";
    const pairing = await resolvePairingWSURL({ env: process.env, config, defaultPort: 8787 });
    console.log(`Pairing WS URL: ${pairing.wsURL} (${pairing.source})`);
    console.log(`Workspace root: ${resolvedWorkspaceRoot} (${workspaceRootSource})`);

    if (defaultEngine === "codex-app-server") {
      const existsOnHost = await stat(resolvedWorkspaceRoot).then(() => true).catch(() => false);
      if (!existsOnHost) {
        console.warn(
          "WARN: Default engine is codex-app-server but the configured workspace root does not exist on this machine. " +
            "Update it with `epoch config` or choose an explicit project folder when creating a project."
        );
      }
    }
  } finally {
    await engines.close();
    await pool.end();
  }
}

function normalizeNonEmptyString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}
