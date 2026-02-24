import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

import type { Turn } from "../types.js";
import { AsyncPushQueue, type CodexEngineSession, type EngineStartTurnArgs, type EngineStartTurnResult, type EngineStreamEvent } from "./types.js";

type PendingRequest = {
  resolve: (value: Record<string, unknown>) => void;
  reject: (err: Error) => void;
};

type ChildNotification = {
  method: string;
  params?: unknown;
};

type ChildServerRequest = {
  id: string | number;
  method: string;
  params?: unknown;
};

type ChildEvent = ChildNotification | ChildServerRequest;

type ChildSubscriber = (event: ChildEvent) => void;

function isServerRequest(message: unknown): message is ChildServerRequest {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return (typeof obj.id === "string" || typeof obj.id === "number") && typeof obj.method === "string";
}

function isNotification(message: unknown): message is ChildNotification {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return typeof obj.method === "string" && obj.id == null;
}

function isResponse(message: unknown): message is { id: string | number; result?: unknown; error?: { code: number; message: string; data?: unknown } } {
  if (!message || typeof message !== "object") return false;
  const obj = message as Record<string, unknown>;
  return (typeof obj.id === "string" || typeof obj.id === "number") && typeof obj.method !== "string";
}

export class CodexAppServerEngine implements CodexEngineSession {
  readonly name = "codex-app-server";

  private readonly command: string;
  private readonly args: string[];
  private readonly cwd?: string;
  private readonly env?: NodeJS.ProcessEnv;

  private child: ChildProcessWithoutNullStreams | null = null;
  private lineBuffer = "";
  private requestSeq = 0;
  private pendingRequests = new Map<string, PendingRequest>();
  private subscribers = new Set<ChildSubscriber>();
  private initialized = false;
  private initializePromise: Promise<void> | null = null;

  constructor(opts?: { command?: string; args?: string[]; cwd?: string; env?: NodeJS.ProcessEnv }) {
    this.command = opts?.command ?? "codex";
    this.args = opts?.args ?? ["app-server"];
    this.cwd = opts?.cwd;
    this.env = opts?.env;
  }

  async threadStart(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return await this.request("thread/start", params);
  }

  async threadResume(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return await this.request("thread/resume", params);
  }

  async threadRead(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return await this.request("thread/read", params);
  }

  async threadList(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return await this.request("thread/list", params);
  }

  async modelList(params: Record<string, unknown>): Promise<Record<string, unknown>> {
    return await this.request("model/list", params);
  }

  async startTurn(args: EngineStartTurnArgs): Promise<EngineStartTurnResult> {
    await this.ensureStarted();

    const queue = new AsyncPushQueue<EngineStreamEvent>();
    let streamTurnId: string | null = null;

    const unsubscribe = this.subscribe((event) => {
      const method = String((event as any).method ?? "");
      const params = (event as any).params;
      if (!params || typeof params !== "object") return;

      const eventThreadId = String((params as Record<string, unknown>).threadId ?? "");
      if (eventThreadId !== args.threadId) return;

      if (isServerRequest(event)) {
        const turnId = String((params as Record<string, unknown>).turnId ?? "");
        if (streamTurnId && turnId && streamTurnId !== turnId) return;

        queue.push({
          type: "serverRequest",
          id: event.id,
          method: event.method,
          params: params as Record<string, unknown>,
          respond: async (response) => {
            await this.sendRaw({
              id: event.id,
              ...(response.error ? { error: response.error } : { result: response.result ?? {} }),
            });
          },
        });
        return;
      }

      const turnIdFromPayload = (() => {
        const direct = String((params as Record<string, unknown>).turnId ?? "").trim();
        if (direct) return direct;
        const turnObj = (params as Record<string, unknown>).turn;
        if (turnObj && typeof turnObj === "object") {
          const id = String((turnObj as Record<string, unknown>).id ?? "").trim();
          if (id) return id;
        }
        return "";
      })();

      if (streamTurnId && turnIdFromPayload && streamTurnId !== turnIdFromPayload) {
        return;
      }

      if (!streamTurnId && turnIdFromPayload) {
        streamTurnId = turnIdFromPayload;
      }

      queue.push({
        type: "notification",
        method,
        params: (params as Record<string, unknown>) ?? {},
      });

      if (method === "turn/completed" && streamTurnId) {
        unsubscribe();
        queue.finish();
      }
    });

    try {
      const result = await this.request("turn/start", {
        threadId: args.threadId,
        input: args.input,
        ...(args.cwd ? { cwd: args.cwd } : {}),
        ...(args.model ? { model: args.model } : {}),
        approvalPolicy: args.approvalPolicy,
      });

      const turnRaw = (result.turn ?? null) as Record<string, unknown> | null;
      const turn: Turn = {
        id: String(turnRaw?.id ?? args.turnId),
        items: [],
        status: String(turnRaw?.status ?? "inProgress") as Turn["status"],
        error: (turnRaw?.error as Turn["error"]) ?? null,
      };

      streamTurnId = turn.id;
      return { turn, events: queue };
    } catch (err) {
      unsubscribe();
      queue.finish();
      throw err;
    }
  }

  async interruptTurn(args: { threadId: string; turnId: string }): Promise<void> {
    await this.request("turn/interrupt", {
      threadId: args.threadId,
      turnId: args.turnId,
    });
  }

  async close(): Promise<void> {
    for (const pending of this.pendingRequests.values()) {
      pending.reject(new Error("codex app-server engine closed"));
    }
    this.pendingRequests.clear();
    this.subscribers.clear();

    if (this.child) {
      this.child.kill();
      this.child = null;
    }
  }

  private async ensureStarted() {
    if (this.child) return;

    const child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: { ...process.env, ...(this.env ?? {}) },
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      this.lineBuffer += chunk;
      while (true) {
        const newlineIndex = this.lineBuffer.indexOf("\n");
        if (newlineIndex === -1) break;
        const line = this.lineBuffer.slice(0, newlineIndex).trim();
        this.lineBuffer = this.lineBuffer.slice(newlineIndex + 1);
        if (!line) continue;
        this.handleChildLine(line);
      }
    });

    child.stderr.setEncoding("utf8");
    child.stderr.on("data", () => {
      // Keep stderr attached for diagnostics, but do not surface by default.
    });

    child.on("exit", () => {
      const err = new Error("codex app-server exited");
      for (const pending of this.pendingRequests.values()) {
        pending.reject(err);
      }
      this.pendingRequests.clear();
      this.initialized = false;
      this.initializePromise = null;
      this.child = null;
    });
  }

  private handleChildLine(line: string) {
    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }

    if (isResponse(message)) {
      const key = String(message.id);
      const pending = this.pendingRequests.get(key);
      if (!pending) return;
      this.pendingRequests.delete(key);
      if (message.error) {
        pending.reject(new Error(String(message.error.message ?? "child request failed")));
      } else {
        pending.resolve((message.result as Record<string, unknown>) ?? {});
      }
      return;
    }

    if (isServerRequest(message) || isNotification(message)) {
      for (const subscriber of this.subscribers) {
        subscriber(message);
      }
    }
  }

  private subscribe(listener: ChildSubscriber): () => void {
    this.subscribers.add(listener);
    return () => {
      this.subscribers.delete(listener);
    };
  }

  private async request(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    await this.ensureStarted();
    if (method !== "initialize") {
      await this.ensureInitialized();
    }
    return await this.requestRaw(method, params);
  }

  private async requestRaw(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    const id = ++this.requestSeq;
    await this.sendRaw({ id, method, params });

    return await new Promise<Record<string, unknown>>((resolve, reject) => {
      this.pendingRequests.set(String(id), { resolve, reject });
    });
  }

  private async ensureInitialized() {
    if (this.initialized) return;
    if (this.initializePromise) {
      await this.initializePromise;
      return;
    }

    this.initializePromise = (async () => {
      await this.requestRaw("initialize", {
        clientInfo: {
          name: "@labos/hub",
          version: "0.1.0",
        },
        capabilities: {
          experimentalApi: true,
        },
      });
      await this.sendRaw({
        method: "initialized",
      });
      this.initialized = true;
    })();

    try {
      await this.initializePromise;
    } finally {
      this.initializePromise = null;
    }
  }

  private async sendRaw(payload: Record<string, unknown>) {
    await this.ensureStarted();
    const child = this.child;
    if (!child) throw new Error("codex app-server child process is not running");

    await new Promise<void>((resolve, reject) => {
      child.stdin.write(`${JSON.stringify(payload)}\n`, (err) => {
        if (err) reject(err);
        else resolve();
      });
    });
  }
}
