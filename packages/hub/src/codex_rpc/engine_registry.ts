import type { HubConfig } from "../config.js";
import { CodexAppServerEngine } from "./engines/codex_app_server.js";
import type { CodexEngineSession } from "./engines/types.js";

export type CodexEngineName = "codex-app-server";

const DEFAULT_ENGINE: CodexEngineName = "codex-app-server";

export class CodexEngineRegistry {
  private readonly stateDir: string;
  private codexAppServerEngine: CodexAppServerEngine | null = null;

  constructor(opts: { config: HubConfig | null; stateDir: string }) {
    this.stateDir = opts.stateDir;
    void opts.config;
  }

  defaultEngineName(): CodexEngineName {
    return normalizeEngineName(process.env.LABOS_CODEX_DEFAULT_ENGINE) ?? DEFAULT_ENGINE;
  }

  async getEngine(name: string | null | undefined): Promise<CodexEngineSession> {
    const normalized = normalizeEngineName(name) ?? this.defaultEngineName();
    if (normalized !== "codex-app-server") {
      throw new Error(`Unsupported engine: ${String(name ?? "unknown")}`);
    }

    if (!this.codexAppServerEngine) {
      const command = process.env.LABOS_CODEX_APP_SERVER_BIN?.trim() || "codex";
      const args = process.env.LABOS_CODEX_APP_SERVER_ARGS
        ? process.env.LABOS_CODEX_APP_SERVER_ARGS.split(" ").map((part) => part.trim()).filter(Boolean)
        : ["app-server"];
      this.codexAppServerEngine = new CodexAppServerEngine({
        command,
        args,
        cwd: process.cwd(),
        env: process.env,
      });
    }
    return this.codexAppServerEngine;
  }

  async close() {
    if (this.codexAppServerEngine) {
      await this.codexAppServerEngine.close();
      this.codexAppServerEngine = null;
    }
  }

  stateDirectory(): string {
    return this.stateDir;
  }
}

export function normalizeEngineName(raw: unknown): CodexEngineName | null {
  if (typeof raw !== "string") return null;
  const normalized = raw.trim().toLowerCase();
  if (normalized === "pi" || normalized === "pi-adapter") return "codex-app-server";
  if (normalized === "codex" || normalized === "codex-app-server") return "codex-app-server";
  return null;
}
