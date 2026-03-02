import { stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import WebSocket from "ws";

import { configDir, loadConfig, saveConfig, type BridgeConfig } from "../config.js";
import { isProcessRunning, readBridgeDaemonInfo } from "../daemon.js";
import { createWizardPrompter, createWizardUI } from "./wizard_ui.js";

type ConfigMode = "init" | "config";
type LifecycleAction = "start" | "restart" | "skip";

const CONFIG_USAGE =
  "Usage: epoch-bridge config --hub <ws://.../ws> --token <token> --workspace-root <absolute-path> [--partition <name>] [--account <name>] [--qos <name>] [--time-mins <minutes>] [--cpus <n>] [--mem-mb <n>] [--gpus <n>]";

export type ConfigCommandOptions = {
  mode?: ConfigMode;
  ui?: ReturnType<typeof createWizardUI>;
  prompter?: ReturnType<typeof createWizardPrompter>;
  onLifecycleAction?: (args: { action: LifecycleAction; running: boolean; stateDir: string }) => Promise<void> | void;
};

export async function configCommand(argv: string[], opts: ConfigCommandOptions = {}) {
  const mode = opts?.mode ?? "config";
  const ui = opts.ui ?? createWizardUI();
  const prompter = opts.prompter ?? createWizardPrompter(ui);
  const ownsPrompter = !opts.prompter;
  try {
    const existing = await loadConfig();
    const stateDir = configDir();
    const defaultsFromFlags = parseBridgeConfigFlags(argv);

    const heading = mode === "init" ? "Epoch Bridge Initialization Wizard" : "Epoch Bridge Configuration Wizard";
    ui.banner(heading, "Set Hub URL/token, workspace root, and scheduling defaults");
    ui.step(1, 5, "Load existing bridge configuration", "ok");
    ui.keyValue("Config path", path.join(stateDir, "config.json"));
    ui.keyValue("Existing config", existing ? "present" : "missing");

    const interactive = prompter.interactive;
    const parsed = await collectConfigInputs({
      interactive,
      prompter,
      existing,
      fromFlags: defaultsFromFlags,
      ui,
    });

    if (!parsed.ok) {
      ui.error(parsed.error);
      if (!interactive) {
        ui.line(CONFIG_USAGE);
        process.exitCode = 1;
      }
      return;
    }

    ui.step(2, 5, "Validate required fields", "ok");
    ui.summary("Pending configuration", [
      { key: "hubUrl", before: existing?.hubUrl, after: parsed.config.hubUrl },
      { key: "workspaceRoot", before: existing?.workspaceRoot, after: parsed.config.workspaceRoot },
      {
        key: "token",
        before: existing?.token ? "configured" : "not configured",
        after: parsed.config.token ? "configured" : "not configured",
      },
    ]);

    let connectivityChecked = false;
    let connectivityOk = false;
    if (interactive) {
      const checkConnectivity = await prompter.confirm({
        message: "Run quick Hub connectivity check now?",
        defaultYes: true,
      });
      if (checkConnectivity) {
        connectivityChecked = true;
        const result = await checkHubConnectivity(parsed.config.hubUrl);
        connectivityOk = result.ok;
        if (result.ok) {
          ui.step(3, 5, result.message, "ok");
        } else {
          ui.step(3, 5, result.message, "warn");
        }
      } else {
        ui.step(3, 5, "Connectivity check skipped", "warn");
      }
    } else {
      ui.step(3, 5, "Connectivity check skipped (non-interactive mode)", "info");
    }

    const saved = await saveConfig(parsed.config);
    ui.step(4, 5, "Configuration saved", "ok");
    ui.keyValue("nodeId", saved.nodeId);
    ui.keyValue("hubUrl", saved.hubUrl);
    ui.keyValue("workspaceRoot", saved.workspaceRoot);

    let lifecycleAction: LifecycleAction = "skip";
    let running = false;
    if (interactive) {
      const daemonInfo = await readBridgeDaemonInfo(stateDir);
      running = Boolean(daemonInfo && daemonInfo.pid > 1 && isProcessRunning(daemonInfo.pid));
      const shouldLaunch = await prompter.confirm({
        message: running ? "Restart Epoch Bridge now?" : "Start Epoch Bridge now?",
        defaultYes: true,
      });

      if (shouldLaunch) {
        lifecycleAction = running ? "restart" : "start";
      }
    }

    ui.step(5, 5, "Wizard complete", "ok");
    if (connectivityChecked && !connectivityOk) {
      ui.warn("Hub connectivity failed in preflight, but config was still saved.");
    }

    if (lifecycleAction === "skip") {
      ui.note("Next: run `epoch-bridge start` when ready.");
      return;
    }

    if (opts.onLifecycleAction) {
      await opts.onLifecycleAction({ action: lifecycleAction, running, stateDir });
      return;
    }

    if (lifecycleAction === "restart") {
      const { restartCommand } = await import("./restart.js");
      await restartCommand([]);
      return;
    }

    const { startCommand } = await import("./start.js");
    await startCommand([]);
  } finally {
    if (ownsPrompter) prompter.close();
  }
}

export async function initCommand(argv: string[]) {
  await configCommand(argv, { mode: "init" });
}

export function validateHubUrl(raw: string): string | null {
  const normalized = String(raw ?? "").trim();
  if (!normalized) return "Hub URL is required.";

  try {
    const parsed = new URL(normalized);
    if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
      return "Hub URL must use ws:// or wss://.";
    }
  } catch {
    return "Hub URL is invalid.";
  }
  return null;
}

export function validateWorkspaceRoot(raw: string): string | null {
  const normalized = String(raw ?? "").trim();
  if (!normalized) return "Workspace root is required.";
  if (!path.isAbsolute(normalized)) {
    return "Workspace root must be an absolute path.";
  }
  return null;
}

type BridgeConfigInput = Omit<BridgeConfig, "nodeId">;

async function collectConfigInputs(args: {
  interactive: boolean;
  prompter: ReturnType<typeof createWizardPrompter>;
  existing: BridgeConfig | null;
  fromFlags: Partial<BridgeConfigInput>;
  ui: ReturnType<typeof createWizardUI>;
}): Promise<{ ok: true; config: BridgeConfigInput } | { ok: false; error: string }> {
  const { interactive, prompter, existing, fromFlags, ui } = args;
  const base: BridgeConfigInput = existing
    ? {
        hubUrl: existing.hubUrl,
        token: existing.token,
        workspaceRoot: existing.workspaceRoot,
        defaults: { ...existing.defaults },
      }
    : {
        hubUrl: "",
        token: "",
        workspaceRoot: "",
        defaults: {},
      };

  let hubUrl = fromFlags.hubUrl ?? base.hubUrl ?? "";
  let token = fromFlags.token ?? base.token ?? "";
  let workspaceRoot = fromFlags.workspaceRoot ?? base.workspaceRoot ?? "";

  if (interactive) {
    hubUrl = await prompter.input({
      message: "Hub WS URL",
      defaultValue: hubUrl || "ws://127.0.0.1:8787/ws",
    });
    const tokenPrompt = token ? "Shared token (leave blank to keep current):" : "Shared token:";
    const nextToken = await prompter.secret({ message: tokenPrompt, allowEmpty: Boolean(token) });
    token = nextToken.trim() || token;
    workspaceRoot = await prompter.input({
      message: "Workspace root",
      defaultValue: workspaceRoot || "/tmp/epoch",
    });
  }

  const hubError = validateHubUrl(hubUrl);
  if (hubError) return { ok: false, error: hubError };
  if (!String(token ?? "").trim()) return { ok: false, error: "Shared token is required." };
  const rootError = validateWorkspaceRoot(workspaceRoot);
  if (rootError) return { ok: false, error: rootError };

  const workspaceCheck = await checkWorkspaceRoot(workspaceRoot);
  if (!workspaceCheck.ok) {
    return { ok: false, error: workspaceCheck.message };
  }

  const defaults = {
    partition: fromFlags.defaults?.partition ?? base.defaults.partition,
    account: fromFlags.defaults?.account ?? base.defaults.account,
    qos: fromFlags.defaults?.qos ?? base.defaults.qos,
    timeLimitMinutes: fromFlags.defaults?.timeLimitMinutes ?? base.defaults.timeLimitMinutes,
    cpus: fromFlags.defaults?.cpus ?? base.defaults.cpus,
    memMB: fromFlags.defaults?.memMB ?? base.defaults.memMB,
    gpus: fromFlags.defaults?.gpus ?? base.defaults.gpus,
  };

  if (interactive) {
    ui.line();
    ui.note("Optional scheduler defaults (press Enter to keep current value).");
    defaults.partition = normalizeOptionalString(
      await prompter.input({ message: "Partition", defaultValue: defaults.partition ?? "", allowEmpty: true })
    );
    defaults.account = normalizeOptionalString(
      await prompter.input({ message: "Account", defaultValue: defaults.account ?? "", allowEmpty: true })
    );
    defaults.qos = normalizeOptionalString(await prompter.input({ message: "QOS", defaultValue: defaults.qos ?? "", allowEmpty: true }));
    defaults.timeLimitMinutes = normalizeOptionalNumber(
      await prompter.input({
        message: "Time limit minutes",
        defaultValue: defaults.timeLimitMinutes != null ? String(defaults.timeLimitMinutes) : "",
        allowEmpty: true,
      }),
      { min: 1 }
    );
    defaults.cpus = normalizeOptionalNumber(
      await prompter.input({
        message: "CPUs",
        defaultValue: defaults.cpus != null ? String(defaults.cpus) : "",
        allowEmpty: true,
      }),
      { min: 1 }
    );
    defaults.memMB = normalizeOptionalNumber(
      await prompter.input({
        message: "Memory MB",
        defaultValue: defaults.memMB != null ? String(defaults.memMB) : "",
        allowEmpty: true,
      }),
      { min: 1 }
    );
    defaults.gpus = normalizeOptionalNumber(
      await prompter.input({
        message: "GPUs",
        defaultValue: defaults.gpus != null ? String(defaults.gpus) : "",
        allowEmpty: true,
      }),
      { min: 0 }
    );
  }

  return {
    ok: true,
    config: {
      hubUrl: String(hubUrl).trim(),
      token: String(token).trim(),
      workspaceRoot: String(workspaceRoot).trim(),
      defaults,
    },
  };
}

async function checkWorkspaceRoot(workspaceRoot: string): Promise<{ ok: true } | { ok: false; message: string }> {
  const normalized = String(workspaceRoot ?? "").trim();
  if (!normalized) return { ok: false, message: "Workspace root is required." };

  try {
    const info = await stat(normalized);
    if (!info.isDirectory()) {
      return { ok: false, message: "Workspace root must point to an existing directory." };
    }
    return { ok: true };
  } catch {
    return { ok: false, message: "Workspace root does not exist or is not accessible." };
  }
}

async function checkHubConnectivity(hubUrl: string): Promise<{ ok: boolean; message: string }> {
  const timeoutMs = 2_500;
  return await new Promise((resolve) => {
    const ws = new WebSocket(hubUrl);
    let settled = false;
    let timer: NodeJS.Timeout | null = null;
    const cleanup = () => {
      if (timer) {
        clearTimeout(timer);
      }
      ws.removeListener("open", onOpen);
      ws.removeListener("error", onError);
      ws.removeListener("close", onClose);
    };
    const finish = (result: { ok: boolean; message: string }) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(result);
    };

    const onOpen = () => {
      finish({ ok: true, message: "Hub connectivity check succeeded" });
      ws.close();
    };
    const onError = (err: Error) => {
      finish({ ok: false, message: `Hub connectivity check failed: ${String(err.message ?? err)}` });
    };
    const onClose = () => {
      finish({ ok: false, message: "Hub connectivity check failed: connection closed before ready" });
    };

    timer = setTimeout(() => {
      try {
        ws.terminate();
      } catch {
        // ignore
      }
      finish({ ok: false, message: `Hub connectivity check failed (timeout after ${timeoutMs}ms)` });
    }, timeoutMs);

    ws.once("open", onOpen);
    ws.once("error", onError);
    ws.once("close", onClose);
  });
}

function parseBridgeConfigFlags(argv: string[]): Partial<BridgeConfigInput> {
  const hubUrl = flag(argv, "--hub") ?? undefined;
  const token = flag(argv, "--token") ?? undefined;
  const workspaceRoot = flag(argv, "--workspace-root") ?? undefined;
  return {
    hubUrl,
    token,
    workspaceRoot,
    defaults: {
      partition: normalizeOptionalString(flag(argv, "--partition")),
      account: normalizeOptionalString(flag(argv, "--account")),
      qos: normalizeOptionalString(flag(argv, "--qos")),
      timeLimitMinutes: numFlag(argv, "--time-mins", { min: 1 }),
      cpus: numFlag(argv, "--cpus", { min: 1 }),
      memMB: numFlag(argv, "--mem-mb", { min: 1 }),
      gpus: numFlag(argv, "--gpus", { min: 0 }),
    },
  };
}

function flag(argv: string[], name: string): string | null {
  const idx = argv.indexOf(name);
  if (idx === -1) return null;
  return argv[idx + 1] ?? null;
}

function numFlag(argv: string[], name: string, opts: { min: number }): number | undefined {
  const raw = flag(argv, name);
  if (raw == null) return undefined;
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return undefined;
  if (parsed < opts.min) return undefined;
  return Math.floor(parsed);
}

function normalizeOptionalString(raw: string | null | undefined): string | undefined {
  if (raw == null) return undefined;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

function normalizeOptionalNumber(raw: string, opts: { min: number }): number | undefined {
  const trimmed = raw.trim();
  if (!trimmed) return undefined;
  const parsed = Number(trimmed);
  if (!Number.isFinite(parsed) || parsed < opts.min) return undefined;
  return Math.floor(parsed);
}
