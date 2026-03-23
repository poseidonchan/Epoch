import multipart from "@fastify/multipart";
import Fastify, { type FastifyInstance } from "fastify";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { createReadStream, createWriteStream, existsSync } from "node:fs";
import { appendFile, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pipeline } from "node:stream/promises";
import { v4 as uuidv4 } from "uuid";
import { WebSocketServer, type WebSocket } from "ws";

import { isNodeMethod, isOperatorMethod, type NodeMethod } from "@epoch/protocol";

import { resolveConfiguredWorkspaceRoot, saveHubConfig, type HubConfig } from "./config.js";
import type { DbPool } from "./db/db.js";
import { CodexEngineRegistry } from "./codex_rpc/engine_registry.js";
import { getEnvApiKey, listHubModelsForProvider, resolveHubProvider } from "./model.js";
import { readOpenAISettingsStatus, resolveOpenAIApiKeyFromConfig, resolveOpenAIOcrModelFromConfig } from "./openai_settings.js";
import { sendEvent, sendResError, sendResOk, broadcastEvent } from "./transport/frames.js";
import {
  ensureHubDirs,
  ensureProjectDirs,
  projectBootstrapDir,
  projectCacheDir,
  projectDir,
  projectGeneratedDir,
  projectSessionsDir,
  threadTranscriptPath,
  projectUploadsDir,
  sessionTranscriptPath,
} from "./storage/layout.js";
import {
  normalizeId,
  normalizeOptionalString,
  normalizePermissionLevel,
  normalizeRelativePath,
  sanitizeFilename,
} from "./utils/normalize.js";
import { sleep, toIso } from "./utils/time.js";
import { attachCodexTransport, closeAllCodexTransports, extractCodexAuthToken } from "./codex_rpc/transport.js";
import { CodexRepository } from "./codex_rpc/repository.js";
import {
  getProjectFileIndexRecord,
  listOcrReindexCandidates,
  queueProjectUploadIndexing,
} from "./indexing/projectIndexing.js";
import { extractInlineAttachmentTextForPrompt } from "./indexing/extract.js";
import { fetchUrlContent } from "./indexing/fetchUrl.js";
import { generateSessionTitle } from "./indexing/summarize.js";
import { LocalRuntimeBridge } from "./local_runtime.js";
import { createPushRelayClient } from "./push_relay_client.js";
import { listWorkspaceDirectories, resolveWorkspaceDirectory } from "./workspace_directories.js";
import type { SilentPushSender } from "@epoch/push-relay";

type Role = "operator" | "node";

type HubStartOptions = {
  port: number;
  host: string;
  config: HubConfig;
  stateDir: string;
  pool: DbPool;
  pushSender?: SilentPushSender | null;
};

type ConnectionContext =
  | {
      role: "operator";
      connectionId: string;
      deviceId: string;
      deviceName: string;
      platform: string;
      clientName: string;
      clientVersion: string;
      scopes: string[];
    }
  | {
      role: "node";
      connectionId: string;
      deviceId: string;
      deviceName: string;
      platform: string;
      clientName: string;
      clientVersion: string;
      caps: string[];
      commands: string[];
      permissions: Record<string, unknown>;
    };

type OperatorConn = { ws: WebSocket; ctx: ConnectionContext & { role: "operator" } };
type NodeConn = { ws: WebSocket; ctx: ConnectionContext & { role: "node" } };

type PendingNodeRequest = {
  resolve: (payload: unknown) => void;
  reject: (err: Error) => void;
  timeout: NodeJS.Timeout;
};

type NodeEventSubscriber = (event: string, payload: Record<string, unknown>) => void;

type HpcTres = {
  cpu?: number;
  memMB?: number;
  gpus?: number;
};

type HpcStatus = {
  partition?: string;
  account?: string;
  qos?: string;
  runningJobs: number;
  pendingJobs: number;
  limit?: HpcTres;
  inUse?: HpcTres;
  available?: HpcTres;
  requestable?: HpcTres;
  supplyPool?: HpcSupplyPool;
  nodes?: HpcNodeUsage[];
  updatedAt: string;
};

type HpcSupplyPool = {
  idleNodes: number;
  mixedNodes: number;
  totalNodes: number;
  availableCpu?: number;
  availableMemMB?: number;
  availableGpus?: number;
  scope: "IDLE+MIXED";
  updatedAt: string;
};

type HpcNodeUsage = {
  nodeName: string;
  role: "login" | "compute";
  source: "job" | "node_total_fallback";
  jobIds?: string[];
  cpuPercent: number;
  ramPercent: number;
  gpuPercent?: number;
  updatedAt: string;
};

type ResourceSnapshot = {
  computeConnected: boolean;
  storageUsedPercent: number;
  storageTotalBytes?: number;
  storageUsedBytes?: number;
  storageAvailableBytes?: number;
  cpuPercent: number;
  ramPercent: number;
  gpuPercent?: number;
};

type HpcPrefs = {
  partition?: string;
  account?: string;
  qos?: string;
  updatedAt: string;
  setByDeviceId: string;
};

const PROTOCOL_VERSION = 1;

export type HubHandle = {
  close: () => Promise<void>;
};

export async function upsertNodeConnectionSnapshot(
  pool: DbPool,
  nodeCtx: ConnectionContext & { role: "node" },
  nowIso: string = new Date().toISOString()
) {
  await pool.query(
    `INSERT INTO nodes (
       id, device_id, name, platform, version, caps, commands, permissions, last_seen_at, created_at
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
     ON CONFLICT (id) DO UPDATE SET
       device_id=EXCLUDED.device_id,
       name=EXCLUDED.name,
       platform=EXCLUDED.platform,
       version=EXCLUDED.version,
       caps=EXCLUDED.caps,
       commands=EXCLUDED.commands,
       permissions=EXCLUDED.permissions,
       last_seen_at=EXCLUDED.last_seen_at`,
    [
      nodeCtx.deviceId,
      nodeCtx.deviceId,
      nodeCtx.deviceName,
      nodeCtx.platform,
      nodeCtx.clientVersion,
      JSON.stringify(nodeCtx.caps ?? []),
      JSON.stringify(nodeCtx.commands ?? []),
      JSON.stringify(nodeCtx.permissions ?? {}),
      nowIso,
      nowIso,
    ]
  );
}

export async function startHub(opts: HubStartOptions): Promise<HubHandle> {
  const fastify = Fastify({ logger: true });
  await fastify.register(multipart, {
    limits: {
      fileSize: 1024 * 1024 * 512,
    },
  });

  const state = createHubState(opts);
  const unsubscribeLocalRuntime = state.localRuntime.subscribeNodeEvents((event, payload) => {
    void handleNodeEvent(state, event, payload);
  });
  state.resources = await state.localRuntime.resourceSnapshot().catch(() => state.resources);
  await ensureHubDirs(opts.stateDir);

  if ((process.env.EPOCH_REPAIR_ON_START ?? "1") !== "0") {
    await repairMessagesFromJsonl(state).catch((err) => {
      fastify.log.error({ err }, "startup repair failed");
    });
  }

  if ((process.env.EPOCH_CODEX_BACKFILL_ON_START ?? "1") !== "0") {
    const codexRepository = new CodexRepository({
      pool: opts.pool,
      stateDir: opts.stateDir,
    });
    await codexRepository
      .backfillSessionsMissingThreadMappings({
        staleInProgressThresholdSeconds: 10 * 60,
      })
      .then((summary) => {
        fastify.log.info({ summary }, "codex session/thread backfill completed");
      })
      .catch((err) => {
        fastify.log.error({ err }, "codex session/thread backfill failed");
      });
  }

  registerHttpRoutes(fastify, state);
  void runHighQualityOcrReindexSweep(state, "startup").catch((err) => {
    fastify.log.error({ err }, "startup OCR reindex sweep failed");
  });

  const legacyWss = new WebSocketServer({ noServer: true });
  const codexWss = new WebSocketServer({ noServer: true });
  fastify.server.on("upgrade", (req, socket, head) => {
    const host = req.headers.host ?? "localhost";
    let parsedUrl: URL;
    try {
      parsedUrl = new URL(req.url ?? "/", `http://${host}`);
    } catch {
      socket.destroy();
      return;
    }

    if (parsedUrl.pathname === "/ws") {
      legacyWss.handleUpgrade(req, socket, head, (ws) => {
        legacyWss.emit("connection", ws, req);
      });
      return;
    }

    if (parsedUrl.pathname === "/codex") {
      const token = extractCodexAuthToken(req);
      if (!token || token !== state.config.token) {
        socket.destroy();
        return;
      }
      codexWss.handleUpgrade(req, socket, head, (ws) => {
        codexWss.emit("connection", ws, req);
      });
      return;
    }

    socket.destroy();
  });

  legacyWss.on("connection", (ws) => {
    void handleWsConnection(ws, state);
  });

  codexWss.on("connection", (ws, req) => {
    attachCodexTransport({
      ws,
      request: req,
      config: state.config,
      stateDir: state.stateDir,
      pool: state.pool,
      pushRelayClient: state.pushRelayClient,
      runtimeBridge: {
        isNodeConnected: () => true,
        listNodeCommands: () => state.localRuntime.listNodeCommands(),
        callNode: async (method, params) => {
          const response = await callNode(state, method, params);
          if (!response || typeof response !== "object" || Array.isArray(response)) return {};
          return response as Record<string, unknown>;
        },
        subscribeNodeEvents: (listener) => {
          state.nodeEventSubscribers.add(listener as NodeEventSubscriber);
          return () => {
            state.nodeEventSubscribers.delete(listener as NodeEventSubscriber);
          };
        },
        getSessionPermissionLevel: async (projectId, sessionId) =>
          await getSessionPermissionLevel(state, projectId, sessionId).catch(() => "default"),
        reconcileAgentsFile: async (projectId, source) => {
          await reconcileAgentsFromHpc(state, projectId, source);
        },
      },
    });
  });

  await fastify.listen({ port: opts.port, host: opts.host });
  fastify.log.info(`Epoch Hub listening on http://${opts.host}:${opts.port} (ws: /ws, codex: /codex)`);

  const close = async () => {
    unsubscribeLocalRuntime();
    try {
      for (const op of state.operators) {
        try {
          op.ws.close();
        } catch {
          // ignore
        }
      }
      if (state.node) {
        try {
          state.node.ws.close();
        } catch {
          // ignore
        }
      }
    } catch {
      // ignore
    }

    await new Promise<void>((resolve) => {
      try {
        legacyWss.close(() => resolve());
      } catch {
        resolve();
      }
    });

    await new Promise<void>((resolve) => {
      try {
        codexWss.close(() => resolve());
      } catch {
        resolve();
      }
    });

    await closeAllCodexTransports();

    await fastify.close();
  };

  state.onClose.push(close);

  return { close };
}

function createHubState(opts: HubStartOptions) {
  const engines = new CodexEngineRegistry({ config: opts.config, stateDir: opts.stateDir });
  const workspaceRoot = resolveConfiguredWorkspaceRoot({ stateDir: opts.stateDir, config: opts.config, env: process.env });
  const localRuntime = new LocalRuntimeBridge({
    stateDir: opts.stateDir,
    workspaceRoot,
  });
  const localNodeCtx = createLocalNodeContext(localRuntime);
  const repository = new CodexRepository({
    pool: opts.pool,
    stateDir: opts.stateDir,
  });
  return {
    config: opts.config,
    stateDir: opts.stateDir,
    pool: opts.pool,
    repository,
    engines,
    pushRelayClient: createPushRelayClient({
      config: opts.config,
      repository,
      sender: opts.pushSender ?? null,
    }),
    localRuntime,
    operators: new Set<OperatorConn>(),
    node: { ws: createNoopSocket(), ctx: localNodeCtx } as NodeConn,
    hpcPrefs: null as HpcPrefs | null,
    seq: 0,
    pendingNodeRequests: new Map<string, PendingNodeRequest>(),
    nodeEventSubscribers: new Set<NodeEventSubscriber>(),
    agentsSyncMemo: new Map<string, { hash: string; source: string; ts: number }>(),
    resources: {
      computeConnected: true,
      storageUsedPercent: 0,
      cpuPercent: 0,
      ramPercent: 0,
    } as ResourceSnapshot,
    ocrReindexSweepInFlight: false,
    onClose: [] as Array<() => Promise<void>>,
  };
}

type HubState = ReturnType<typeof createHubState>;

function createLocalNodeContext(localRuntime: LocalRuntimeBridge): ConnectionContext & { role: "node" } {
  return {
    role: "node",
    connectionId: "local-runtime",
    deviceId: "local-runtime",
    deviceName: "Epoch Local Runtime",
    platform: process.platform,
    clientName: "epoch",
    clientVersion: "0.1.0",
    caps: ["fs", "artifacts", "logs", "shell"],
    commands: localRuntime.listNodeCommands(),
    permissions: {
      workspaceRoot: localRuntime.workspaceRoot(),
    },
  };
}

function createNoopSocket(): WebSocket {
  return {
    send() {},
    close() {},
  } as unknown as WebSocket;
}

function codexRepositoryForState(state: HubState): CodexRepository {
  return state.repository;
}

function requireHttpAuth(state: HubState, req: { headers: Record<string, string | string[] | undefined> }) {
  const header = req.headers["authorization"];
  const value = Array.isArray(header) ? header[0] : header;
  if (!value) return false;
  const token = value.replace(/^Bearer\s+/i, "");
  return token === state.config.token;
}

function registerHttpRoutes(fastify: FastifyInstance, state: HubState) {
  fastify.get("/status/resources", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    state.resources = await state.localRuntime.resourceSnapshot().catch(() => state.resources);
    return reply.send(state.resources);
  });

  fastify.post("/projects/:projectId/uploads", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    const projectId = normalizeId((req.params as any).projectId as string);

    const part = await (req as any).file();
    if (!part) return reply.code(400).send({ error: "missing file" });

    const uploadId = uuidv4();
    const originalName = sanitizeFilename(part.filename ?? "upload.bin");

    await ensureProjectDirs(state, projectId);
    const storedName = `${uploadId}__${originalName}`;
    const storedPath = path.join(projectUploadsDir(state, projectId), storedName);

    await pipeline(part.file, createWriteStream(storedPath));

    const st = await stat(storedPath);
    const contentType = part.mimetype ?? null;

    await state.pool.query(
      `INSERT INTO uploads (id, project_id, original_name, stored_path, content_type, size_bytes, created_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [uploadId, projectId, originalName, storedPath, contentType, st.size, new Date().toISOString()]
    );

    const artifactPath = `uploads/${originalName}`;
    await upsertArtifact(state, {
      projectId,
      path: artifactPath,
      origin: "user_upload",
      modifiedAt: new Date().toISOString(),
      sizeBytes: st.size,
    });

    await enqueueUploadIndexing(state, {
      projectId,
      artifactPath,
      uploadId,
      storedPath,
      contentType,
    });

    broadcastEvent(state, "artifacts.updated", {
      projectId,
      artifact: await getArtifactByPath(state, projectId, artifactPath),
      change: "created",
    });

    return reply.send({ uploadId, path: artifactPath, indexStatus: "processing" });
  });

  fastify.get("/projects/:projectId/uploads/:uploadId", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    const projectId = normalizeId((req.params as any).projectId as string);
    const uploadId = normalizeId((req.params as any).uploadId as string);

    const row = await state.pool.query<{ stored_path: string; content_type: string | null }>(
      "SELECT stored_path, content_type FROM uploads WHERE id=$1 AND project_id=$2",
      [uploadId, projectId]
    );
    if (row.rows.length === 0) return reply.code(404).send({ error: "not found" });

    const storedPath = row.rows[0].stored_path;
    const contentType = row.rows[0].content_type;
    if (contentType) reply.header("content-type", contentType);
    return reply.send(createReadStream(storedPath));
  });

  fastify.post("/projects/:projectId/links", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    const projectId = normalizeId((req.params as any).projectId as string);
    if (!projectId) return reply.code(400).send({ error: "missing projectId" });

    const body = req.body as Record<string, unknown> | undefined;
    const rawUrl = String(body?.url ?? "").trim();
    if (!rawUrl) return reply.code(400).send({ error: "missing url" });

    let parsed: URL;
    try {
      parsed = new URL(rawUrl);
    } catch {
      return reply.code(400).send({ error: "invalid url" });
    }
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return reply.code(400).send({ error: "only http/https URLs are supported" });
    }

    const uploadId = uuidv4();
    const hostSlug = sanitizeFilename(parsed.hostname).slice(0, 40);
    const hash = createHash("sha256").update(rawUrl).digest("hex").slice(0, 12);
    const artifactPath = `links/${hostSlug}-${hash}.txt`;

    await ensureProjectDirs(state, projectId);

    await upsertArtifact(state, {
      projectId,
      path: artifactPath,
      origin: "link_upload",
      modifiedAt: new Date().toISOString(),
      sourceUrl: rawUrl,
    });

    const now = new Date().toISOString();
    await state.pool.query(
      `INSERT INTO project_file_index (
          project_id, artifact_path, upload_id, status, created_at, updated_at
        ) VALUES ($1,$2,$3,'processing',$4,$4)
        ON CONFLICT (project_id, artifact_path) DO UPDATE SET
          upload_id=EXCLUDED.upload_id,
          status='processing',
          error=NULL,
          updated_at=EXCLUDED.updated_at,
          completed_at=NULL`,
      [projectId, artifactPath, uploadId, now]
    );

    broadcastEvent(state, "artifacts.updated", {
      projectId,
      artifact: await getArtifactByPath(state, projectId, artifactPath),
      change: "created",
    });

    // Fire-and-forget: fetch URL, save text, run indexing pipeline
    void (async () => {
      try {
        const fetched = await fetchUrlContent(rawUrl);
        const storedDir = projectUploadsDir(state, projectId);
        await mkdir(storedDir, { recursive: true });
        const storedPath = path.join(storedDir, `${uploadId}__${hostSlug}-${hash}.txt`);
        await writeFile(storedPath, fetched.textContent, "utf8");

        await state.pool.query(
          `INSERT INTO uploads (id, project_id, original_name, stored_path, content_type, size_bytes, created_at)
           VALUES ($1,$2,$3,$4,$5,$6,$7)`,
          [uploadId, projectId, rawUrl, storedPath, fetched.contentType, fetched.byteLength, new Date().toISOString()]
        );

        await enqueueUploadIndexing(state, {
          projectId,
          artifactPath,
          uploadId,
          storedPath,
          contentType: "text/plain",
        });
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err ?? "Unknown error");
        console.error(`[link-upload] Failed to fetch/index ${rawUrl} for project ${projectId}: ${message}`);
        await state.pool.query(
          `UPDATE project_file_index SET status='failed', error=$3, updated_at=$4
           WHERE project_id=$1 AND artifact_path=$2`,
          [projectId, artifactPath, message.slice(0, 600), new Date().toISOString()]
        );
        broadcastEvent(state, "artifacts.updated", {
          projectId,
          artifact: await getArtifactByPath(state, projectId, artifactPath),
          change: "updated",
        });
      }
    })();

    return reply.send({ uploadId, path: artifactPath, indexStatus: "processing" });
  });

  fastify.get("/projects/:projectId/artifacts/content", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    const projectId = normalizeId((req.params as any).projectId as string);
    const artifactPath = (req.query as any).path as string | undefined;
    if (!artifactPath) return reply.code(400).send({ error: "missing path" });

    const cleanPath = normalizeRelativePath(artifactPath);
    if (!cleanPath) return reply.code(400).send({ error: "invalid path" });

    const artifact = await getArtifactByPath(state, projectId, cleanPath);
    if (!artifact) return reply.code(404).send({ error: "not found" });

    if (artifact.origin === "user_upload") {
      const originalName = path.posix.basename(cleanPath);
      const uploadRow = await state.pool.query<{ stored_path: string; content_type: string | null }>(
        "SELECT stored_path, content_type FROM uploads WHERE project_id=$1 AND original_name=$2 ORDER BY created_at DESC LIMIT 1",
        [projectId, originalName]
      );
      if (uploadRow.rows.length === 0) return reply.code(404).send({ error: "not found" });
      const indexRecord = await getProjectFileIndexRecord(state.pool, projectId, cleanPath);
      if (indexRecord?.extractedText) return reply.send(indexRecord.extractedText);
      if (indexRecord?.status === "processing") {
        return reply.send("File is processing for indexing. Content preview will be available shortly.");
      }
      if (indexRecord?.status === "failed") {
        return reply.send(indexRecord.error ? `Indexing failed: ${indexRecord.error}` : "Indexing failed for this file.");
      }
      const storedPath = uploadRow.rows[0].stored_path;
      const contentType = (uploadRow.rows[0].content_type ?? "").toLowerCase();
      if (!contentType.startsWith("text/") && !contentType.includes("json") && !contentType.includes("xml")) {
        return reply.send("Binary file preview unavailable. File is uploaded and awaiting/using indexed text content.");
      }
      const raw = await readFile(storedPath, "utf8");
      return reply.send(raw);
    }

    if (state.localRuntime) {
      const res = await callNode(state, "runtime.fs.read", {
        projectId,
        path: cleanPath,
        offset: 0,
        length: 1024 * 1024,
        encoding: "utf8",
      });
      const data = (res as any).data;
      return reply.send(typeof data === "string" ? data : "");
    }

    const generatedPath = path.join(projectGeneratedDir(state, projectId), cleanPath);
    try {
      const raw = await readFile(generatedPath);
      return reply.send(raw.toString("utf8"));
    } catch {
      return reply.send("Preview not available (no node connected).");
    }
  });

  fastify.get("/projects/:projectId/artifacts/raw", async (req, reply) => {
    if (!requireHttpAuth(state, req)) return reply.code(401).send({ error: "unauthorized" });
    const projectId = normalizeId((req.params as any).projectId as string);
    const artifactPath = (req.query as any).path as string | undefined;
    if (!artifactPath) return reply.code(400).send({ error: "missing path" });

    const cleanPath = normalizeRelativePath(artifactPath);
    if (!cleanPath) return reply.code(400).send({ error: "invalid path" });

    const artifact = await getArtifactByPath(state, projectId, cleanPath);
    if (!artifact) return reply.code(404).send({ error: "not found" });

    const ext = path.posix.extname(cleanPath).toLowerCase();
    const contentType = (() => {
      switch (ext) {
        case ".png":
          return "image/png";
        case ".jpg":
        case ".jpeg":
          return "image/jpeg";
        case ".gif":
          return "image/gif";
        case ".svg":
          return "image/svg+xml";
        default:
          return "application/octet-stream";
      }
    })();

    reply.header("content-type", contentType);
    reply.header("cache-control", "private, max-age=60");

    if (artifact.origin === "user_upload") {
      const originalName = path.posix.basename(cleanPath);
      const uploadRow = await state.pool.query<{ stored_path: string }>(
        "SELECT stored_path FROM uploads WHERE project_id=$1 AND original_name=$2 ORDER BY created_at DESC LIMIT 1",
        [projectId, originalName]
      );
      if (uploadRow.rows.length === 0) return reply.code(404).send({ error: "not found" });
      const storedPath = uploadRow.rows[0].stored_path;
      return reply.send(createReadStream(storedPath));
    }

    const MAX_BYTES = 10 * 1024 * 1024;
    if (state.localRuntime) {
      const chunks: Buffer[] = [];
      let offset = 0;
      let total = 0;
      const CHUNK = 256 * 1024;

      while (true) {
        const res = await callNode(state, "runtime.fs.read", {
          projectId,
          path: cleanPath,
          offset,
          length: CHUNK,
          encoding: "base64",
        });

        const data = (res as any).data;
        const eof = Boolean((res as any).eof);
        if (typeof data !== "string") break;

        const buf = Buffer.from(data, "base64");
        if (buf.length === 0) break;

        if (total + buf.length > MAX_BYTES) {
          return reply.code(413).send({ error: "file too large to preview" });
        }

        chunks.push(buf);
        total += buf.length;
        offset += buf.length;
        if (eof) break;
      }

      return reply.send(Buffer.concat(chunks));
    }

    const generatedPath = path.join(projectGeneratedDir(state, projectId), cleanPath);
    try {
      const st = await stat(generatedPath);
      if (st.size > MAX_BYTES) return reply.code(413).send({ error: "file too large to preview" });
      return reply.send(createReadStream(generatedPath));
    } catch {
      return reply.code(404).send({ error: "not found" });
    }
  });
}

async function handleWsConnection(ws: WebSocket, state: HubState) {
  const nonce = randomBytes(32).toString("base64url");
  const issuedAt = new Date().toISOString();
  const serverId = state.config.serverId;

  sendEvent(ws, state, "connect.challenge", {
    nonce,
    issuedAt,
    serverId,
    protocol: { min: PROTOCOL_VERSION, max: PROTOCOL_VERSION },
    hmac: { alg: "HMAC-SHA256" },
  });

  let ctx: ConnectionContext | null = null;
  const connectTimer = setTimeout(() => {
    if (!ctx) {
      ws.close(4401, "connect timeout");
    }
  }, 5_000);

  ws.on("message", (data) => {
    void (async () => {
      const text = data.toString();
      let msg: any;
      try {
        msg = JSON.parse(text);
      } catch {
        ws.close(4400, "bad json");
        return;
      }

      if (!ctx) {
        const isConnect = msg?.type === "req" && msg?.method === "connect";
        if (!isConnect) {
          sendResError(ws, msg?.id ?? "unknown", "BAD_REQUEST", "First request must be connect");
          ws.close(4400, "connect required");
          return;
        }

        const params = msg?.params ?? {};
        const token = params?.auth?.token;
        const signature = params?.auth?.signature;
        const role = params?.role as Role | undefined;
        if (typeof token !== "string" || typeof signature !== "string" || (role !== "operator" && role !== "node")) {
          sendResError(ws, msg.id, "BAD_REQUEST", "Invalid connect params");
          ws.close(4400, "bad connect");
          return;
        }
        if (token !== state.config.token) {
          sendResError(ws, msg.id, "AUTH_FAILED", "Invalid token");
          ws.close(4403, "auth failed");
          return;
        }

        const expected = createHmac("sha256", token).update(nonce).digest("base64url");
        if (signature !== expected) {
          sendResError(ws, msg.id, "AUTH_FAILED", "Invalid signature");
          ws.close(4403, "auth failed");
          return;
        }

        const minProtocol = Number(params?.minProtocol);
        const maxProtocol = Number(params?.maxProtocol);
        if (!(minProtocol <= PROTOCOL_VERSION && PROTOCOL_VERSION <= maxProtocol)) {
          sendResError(ws, msg.id, "BAD_REQUEST", "Unsupported protocol range");
          ws.close(4400, "bad protocol");
          return;
        }

        const connectionId = uuidv4();
        const device = params?.device ?? {};
        const client = params?.client ?? {};
        const deviceId = typeof device?.id === "string" ? device.id : uuidv4();
        const deviceName = typeof device?.name === "string" ? device.name : "unknown";
        const platform = typeof device?.platform === "string" ? device.platform : "unknown";
        const clientName = typeof client?.name === "string" ? client.name : "unknown";
        const clientVersion = typeof client?.version === "string" ? client.version : "unknown";

        if (role === "operator") {
          ctx = {
            role,
            connectionId,
            deviceId,
            deviceName,
            platform,
            clientName,
            clientVersion,
            scopes: Array.isArray(params?.scopes) ? params.scopes : [],
          };
          state.operators.add({ ws, ctx });
        } else {
          const nodeCtx: ConnectionContext & { role: "node" } = {
            role,
            connectionId,
            deviceId,
            deviceName,
            platform,
            clientName,
            clientVersion,
            caps: Array.isArray(params?.caps) ? params.caps : [],
            commands: Array.isArray(params?.commands) ? params.commands : [],
            permissions: typeof params?.permissions === "object" && params.permissions ? params.permissions : {},
          };
          ctx = nodeCtx;
          state.node = { ws, ctx: nodeCtx };
          state.resources.computeConnected = true;
          try {
            await upsertNodeConnectionSnapshot(state.pool, nodeCtx);
          } catch (err) {
            console.warn("failed to persist node connection snapshot", { err, deviceId: nodeCtx.deviceId });
          }

          if (state.hpcPrefs) {
            void callNode(state, "hpc.prefs.set", {
              partition: state.hpcPrefs.partition ?? null,
              account: state.hpcPrefs.account ?? null,
              qos: state.hpcPrefs.qos ?? null,
            }).catch(() => {
              // ignore; node may not support the method yet
            });
          }

          void drainWorkspaceProvisioningQueue(state).catch(() => {
            // best effort
          });
        }

        clearTimeout(connectTimer);
        sendResOk(ws, msg.id, {
          protocol: PROTOCOL_VERSION,
          connectionId,
          roleAccepted: role,
          scopesAccepted: role === "operator" ? (ctx as any).scopes : undefined,
          commandsAccepted: role === "node" ? (ctx as any).commands : undefined,
          server: { name: "epoch", version: "0.1.0" },
        });
        return;
      }

      // Connected: handle frames
      if (ctx.role === "operator") {
        if (msg?.type !== "req") {
          return;
        }
        await handleOperatorRequest(state, ws, ctx, msg);
        return;
      }

      // Node connection
      if (msg?.type === "res") {
        const pending = state.pendingNodeRequests.get(msg.id);
        if (!pending) return;
        clearTimeout(pending.timeout);
        state.pendingNodeRequests.delete(msg.id);
        if (msg.ok) pending.resolve(msg.payload ?? {});
        else pending.reject(new Error(msg?.error?.message ?? "node request failed"));
        return;
      }

      if (msg?.type === "event") {
        await handleNodeEvent(state, msg.event, msg.payload ?? {});
        return;
      }
    })();
  });

  ws.on("close", () => {
    clearTimeout(connectTimer);
    if (!ctx) return;
    if (ctx.role === "operator") {
      for (const conn of state.operators) {
        if (conn.ws === ws) {
          state.operators.delete(conn);
          break;
        }
      }
    } else {
      if (state.node?.ws === ws) {
        state.node = { ws: createNoopSocket(), ctx: createLocalNodeContext(state.localRuntime) } as NodeConn;
        state.resources.computeConnected = true;
      }
    }
  });
}

async function handleOperatorRequest(state: HubState, ws: WebSocket, ctx: ConnectionContext & { role: "operator" }, msg: any) {
  const id = msg.id as string;
  const method = msg.method as string;
  const params = (msg.params ?? {}) as Record<string, any>;

  try {
    if (!isOperatorMethod(method)) {
      sendResError(ws, id, "BAD_REQUEST", `Unknown method: ${method}`);
      return;
    }
    switch (method) {
      case "projects.list": {
        const projects = await listProjects(state);
        sendResOk(ws, id, { projects });
        return;
      }
      case "projects.create": {
        const name = String(params.name ?? "").trim() || "Untitled Project";
        const workspacePath = normalizeOptionalString(params.workspacePath);
        const project = await createProject(state, name, workspacePath ?? undefined);
        sendResOk(ws, id, { project });
        broadcastEvent(state, "projects.updated", { project, change: "created" });
        return;
      }
      case "projects.rename": {
        const projectId = normalizeId(params.projectId);
        const name = String(params.name ?? "").trim();
        if (!projectId || !name) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or name");
          return;
        }
        const project = await renameProject(state, projectId, name);
        if (!project) {
          sendResError(ws, id, "NOT_FOUND", "Project not found");
          return;
        }
        sendResOk(ws, id, { project });
        broadcastEvent(state, "projects.updated", { project, change: "updated" });
        return;
      }
      case "projects.update": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const patch: {
          codexApprovalPolicy?: string | null;
          codexSandboxJson?: string | null;
        } = {};
        if (Object.prototype.hasOwnProperty.call(params, "codexApprovalPolicy")) {
          patch.codexApprovalPolicy = normalizeOptionalString(params.codexApprovalPolicy);
        }
        if (Object.prototype.hasOwnProperty.call(params, "codexSandbox")) {
          patch.codexSandboxJson = safeJsonString(params.codexSandbox);
        }
        if (
          !Object.prototype.hasOwnProperty.call(params, "codexApprovalPolicy")
          && !Object.prototype.hasOwnProperty.call(params, "codexSandbox")
        ) {
          sendResError(ws, id, "BAD_REQUEST", "No updatable fields were provided");
          return;
        }
        const project = await updateProject(state, projectId, patch);
        if (!project) {
          sendResError(ws, id, "NOT_FOUND", "Project not found");
          return;
        }
        sendResOk(ws, id, { project });
        broadcastEvent(state, "projects.updated", { project, change: "updated" });
        return;
      }
      case "projects.delete": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const deletedProject = await deleteProject(state, projectId);
        if (!deletedProject) {
          sendResError(ws, id, "NOT_FOUND", "Project not found");
          return;
        }
        sendResOk(ws, id, { ok: true });
        broadcastEvent(state, "projects.updated", { project: deletedProject, change: "deleted" });
        return;
      }
      case "sessions.list": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const includeArchived = Boolean(params.includeArchived ?? false);
        const sessions = await listSessions(state, projectId, { includeArchived });
        sendResOk(ws, id, { sessions });
        return;
      }
      case "sessions.create": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const titleRaw = params.title == null ? null : String(params.title);
        const session = await createSession(state, projectId, titleRaw);
        if (!session) {
          sendResError(ws, id, "NOT_FOUND", "Project not found");
          return;
        }
        sendResOk(ws, id, { session });
        broadcastEvent(state, "sessions.updated", { session, change: "created" });
        return;
      }
      case "sessions.update": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        if (!projectId || !sessionId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or sessionId");
          return;
        }
        const title = params.title == null ? undefined : String(params.title).trim();
        const lifecycle = params.lifecycle == null ? undefined : String(params.lifecycle);
        const backendEngine =
          params.backendEngine == null ? undefined : (normalizeCodexEngine(params.backendEngine) ?? undefined);
        const codexModel = Object.prototype.hasOwnProperty.call(params, "codexModel")
          ? normalizeOptionalString(params.codexModel)
          : undefined;
        const codexModelProvider = Object.prototype.hasOwnProperty.call(params, "codexModelProvider")
          ? normalizeOptionalString(params.codexModelProvider)
          : undefined;
        const codexApprovalPolicy = Object.prototype.hasOwnProperty.call(params, "codexApprovalPolicy")
          ? normalizeOptionalString(params.codexApprovalPolicy)
          : undefined;
        const codexSandboxJson = Object.prototype.hasOwnProperty.call(params, "codexSandbox")
          ? safeJsonString(params.codexSandbox)
          : undefined;
        const session = await updateSession(state, projectId, sessionId, {
          title,
          lifecycle,
          backendEngine,
          codexModel,
          codexModelProvider,
          codexApprovalPolicy,
          codexSandboxJson,
        });
        if (!session) {
          sendResError(ws, id, "NOT_FOUND", "Session not found");
          return;
        }
        sendResOk(ws, id, { session });
        broadcastEvent(state, "sessions.updated", { session, change: "updated" });
        return;
      }
      case "sessions.generateTitle": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        if (!projectId || !sessionId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or sessionId");
          return;
        }
        const apiKey = await getApiKeyForProvider(state, "openai");
        const messages = await listMessages(state, projectId, sessionId, { beforeTs: null, limit: 20 });
        if (messages.length === 0) {
          sendResOk(ws, id, {});
          return;
        }
        const title = await generateSessionTitle(
          messages.map((m: any) => ({ role: m.role, text: m.text })),
          { apiKey }
        );
        if (!title) {
          sendResOk(ws, id, {});
          return;
        }
        const session = await updateSession(state, projectId, sessionId, { title });
        if (!session) {
          sendResOk(ws, id, {});
          return;
        }
        sendResOk(ws, id, { session });
        broadcastEvent(state, "sessions.updated", { session, change: "updated" });
        return;
      }
      case "sessions.permission.set": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        const level = normalizePermissionLevel(params.level);
        if (!projectId || !sessionId || !level) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId/sessionId or invalid level");
          return;
        }
        const previousLevel = await getSessionPermissionLevel(state, projectId, sessionId).catch(() => "default" as const);
        const ok = await setSessionPermissionLevel(state, projectId, sessionId, level, ctx.deviceId);
        if (!ok) {
          sendResError(ws, id, "NOT_FOUND", "Session not found");
          return;
        }
        await insertSessionPermissionEvent(state, {
          id: uuidv4(),
          projectId,
          sessionId,
          level,
          previousLevel,
          changedByDeviceId: ctx.deviceId,
        }).catch(() => {
          // best effort audit trail
        });
        await appendPermissionChangeCodexItem(state, {
          projectId,
          sessionId,
          previousLevel,
          level,
          changedByDeviceId: ctx.deviceId,
        }).catch(() => {
          // best effort replay event
        });
        sendResOk(ws, id, { ok: true, level });
        broadcastEvent(state, "sessions.permission.updated", { projectId, sessionId, level, updatedAt: new Date().toISOString() });
        return;
      }
      case "sessions.context.get": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        if (!projectId || !sessionId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or sessionId");
          return;
        }
        const stats = await getSessionContextStats(state, projectId, sessionId);
        if (!stats) {
          sendResError(ws, id, "NOT_FOUND", "Session not found");
          return;
        }
        sendResOk(ws, id, { context: stats });
        return;
      }
      case "sessions.delete": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        if (!projectId || !sessionId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or sessionId");
          return;
        }
        const deletedSession = await deleteSession(state, projectId, sessionId);
        if (!deletedSession) {
          sendResError(ws, id, "NOT_FOUND", "Session not found");
          return;
        }
        sendResOk(ws, id, { ok: true });
        broadcastEvent(state, "sessions.updated", { session: deletedSession, change: "deleted" });
        return;
      }
      case "models.current": {
        const resolved = resolveHubProvider(state.config);
        const provider = resolved.provider;

        // Try to fetch models dynamically from the Codex app-server engine
        try {
          const engine = await state.engines.getEngine(null);
          if (engine.modelList) {
            const engineResult = await engine.modelList({});
            const data = (engineResult as any).data as Array<{
              id: string;
              provider?: string;
              displayName?: string;
              supportedReasoningEfforts?: Array<{ reasoningEffort: string; description?: string }>;
              defaultReasoningEffort?: string;
              isDefault?: boolean;
            }>;
            if (Array.isArray(data) && data.length > 0) {
              const models = data.map((m) => {
                const efforts = m.supportedReasoningEfforts ?? [];
                const hasReasoning = efforts.length > 0 && !efforts.every((e) => e.reasoningEffort === "none");
                const thinkingLevels = hasReasoning
                  ? efforts.map((e) => e.reasoningEffort).filter((e) => e !== "none")
                  : [];
                return {
                  id: m.id,
                  provider: typeof m.provider === "string" && m.provider.trim().length > 0 ? m.provider.trim() : provider,
                  name: m.displayName ?? m.id,
                  reasoning: hasReasoning,
                  thinkingLevels,
                };
              });
              let defaultModelId = data.find((m) => m.isDefault)?.id ?? resolved.defaultModelId;
              if (defaultModelId && !models.some((m) => m.id === defaultModelId)) {
                defaultModelId = null;
              }
              if (!defaultModelId) {
                defaultModelId = models[0]?.id ?? "";
              }
              // Global thinkingLevels = union of all models' levels, preserving order
              const allLevels = new Map<string, true>();
              for (const m of models) {
                for (const l of m.thinkingLevels) allLevels.set(l, true);
              }
              sendResOk(ws, id, {
                provider,
                defaultModelId,
                models,
                thinkingLevels: [...allLevels.keys()],
              });
              return;
            }
          }
        } catch {
          // Fall through to hardcoded registry
        }

        // Fallback: use hardcoded MODEL_REGISTRY
        const models = listHubModelsForProvider(provider);
        let defaultModelId = resolved.defaultModelId;
        if (defaultModelId && !models.some((m) => m.id === defaultModelId)) {
          defaultModelId = null;
        }
        if (!defaultModelId) {
          defaultModelId = models[0]?.id ?? "";
        }
        sendResOk(ws, id, {
          provider,
          defaultModelId,
          models: models.map((m) => ({
            ...m,
            provider,
            thinkingLevels: m.reasoning ? ["minimal", "low", "medium", "high", "xhigh"] : [],
          })),
          thinkingLevels: ["minimal", "low", "medium", "high", "xhigh"],
        });
        return;
      }
      case "push.device.register": {
        const installationId = normalizeOptionalString(params.installationId);
        const apnsToken = normalizeOptionalString(params.apnsToken);
        const environment = normalizeOptionalString(params.environment);
        const deviceName = normalizeOptionalString(params.deviceName);
        const platform = normalizeOptionalString(params.platform);
        if (!installationId || !apnsToken || !environment || !deviceName || !platform) {
          sendResError(ws, id, "BAD_REQUEST", "Missing installationId/apnsToken/environment/deviceName/platform");
          return;
        }
        await codexRepositoryForState(state).upsertPushDevice({
          serverId: state.config.serverId,
          installationId,
          apnsToken,
          environment,
          deviceName,
          platform,
          seenAt: new Date().toISOString(),
        });
        void state.pushRelayClient.registerDevice({
          serverId: state.config.serverId,
          installationId,
          apnsToken,
          environment,
          deviceName,
          platform,
        }).catch(() => {
          // best effort relay fanout registration
        });
        sendResOk(ws, id, {
          ok: true,
          serverId: state.config.serverId,
        });
        return;
      }
      case "push.device.unregister": {
        const installationId = normalizeOptionalString(params.installationId);
        if (!installationId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing installationId");
          return;
        }
        await codexRepositoryForState(state).deletePushDevice({
          serverId: state.config.serverId,
          installationId,
        });
        void state.pushRelayClient.unregisterDevice({
          serverId: state.config.serverId,
          installationId,
        }).catch(() => {
          // best effort relay fanout unregister
        });
        sendResOk(ws, id, {
          ok: true,
          serverId: state.config.serverId,
        });
        return;
      }
      case "push.device.heartbeat": {
        const installationId = normalizeOptionalString(params.installationId);
        if (!installationId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing installationId");
          return;
        }
        const repository = codexRepositoryForState(state);
        const registered = (await repository.listPushDevices({ serverId: state.config.serverId }))
          .find((device) => device.installationId == installationId);
        if (!registered) {
          sendResError(ws, id, "NOT_FOUND", "Push device not registered");
          return;
        }
        await repository.upsertPushDevice({
          serverId: state.config.serverId,
          installationId,
          apnsToken: normalizeOptionalString(params.apnsToken) ?? registered.apnsToken,
          environment: normalizeOptionalString(params.environment) ?? registered.environment,
          deviceName: normalizeOptionalString(params.deviceName) ?? registered.deviceName,
          platform: normalizeOptionalString(params.platform) ?? registered.platform,
          seenAt: new Date().toISOString(),
        });
        void state.pushRelayClient.heartbeatDevice({
          serverId: state.config.serverId,
          installationId,
          apnsToken: normalizeOptionalString(params.apnsToken),
          environment: normalizeOptionalString(params.environment),
          deviceName: normalizeOptionalString(params.deviceName),
          platform: normalizeOptionalString(params.platform),
        }).catch(() => {
          // best effort relay heartbeat
        });
        sendResOk(ws, id, {
          ok: true,
          serverId: state.config.serverId,
        });
        return;
      }
      case "hpc.prefs.set": {
        const partition = normalizeOptionalString(params.partition);
        const account = normalizeOptionalString(params.account);
        const qos = normalizeOptionalString(params.qos);
        state.hpcPrefs = {
          partition,
          account,
          qos,
          updatedAt: new Date().toISOString(),
          setByDeviceId: ctx.deviceId,
        };

        if (state.node) {
          void callNode(state, "hpc.prefs.set", { partition: partition ?? null, account: account ?? null, qos: qos ?? null }).catch(() => {
            // ignore; node may be offline or not support the method
          });
        }

        sendResOk(ws, id, { ok: true });
        return;
      }
      case "chat.history": {
        const projectId = normalizeId(params.projectId);
        const sessionId = normalizeId(params.sessionId);
        const beforeTs = params.beforeTs == null ? null : String(params.beforeTs);
        const limit = params.limit == null ? 50 : Math.min(200, Math.max(1, Number(params.limit)));
        if (!projectId || !sessionId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or sessionId");
          return;
        }
        const messages = await listMessages(state, projectId, sessionId, { beforeTs, limit });
        sendResOk(ws, id, { messages });
        return;
      }
      case "runs.list": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const runs = await listRuns(state, projectId);
        sendResOk(ws, id, { runs });
        return;
      }
      case "runs.get": {
        const projectId = normalizeId(params.projectId);
        const runId = normalizeId(params.runId);
        if (!projectId || !runId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or runId");
          return;
        }
        const run = await getRun(state, projectId, runId);
        if (!run) {
          sendResError(ws, id, "NOT_FOUND", "Run not found");
          return;
        }
        sendResOk(ws, id, { run });
        return;
      }
      case "artifacts.list": {
        const projectId = normalizeId(params.projectId);
        const prefix = params.prefix == null ? null : String(params.prefix);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const artifacts = await listArtifacts(state, projectId, { prefix });
        sendResOk(ws, id, { artifacts });
        return;
      }
      case "artifacts.get": {
        const projectId = normalizeId(params.projectId);
        const artifactPath = String(params.path ?? "");
        if (!projectId || !artifactPath) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or path");
          return;
        }
        const artifact = await getArtifactByPath(state, projectId, artifactPath);
        if (!artifact) {
          sendResError(ws, id, "NOT_FOUND", "Artifact not found");
          return;
        }
        sendResOk(ws, id, { artifact });
        return;
      }
      case "artifacts.delete": {
        const projectId = normalizeId(params.projectId);
        const artifactPath = String(params.path ?? "");
        if (!projectId || !artifactPath) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or path");
          return;
        }
        const deleted = await deleteArtifact(state, projectId, artifactPath);
        if (!deleted) {
          sendResError(ws, id, "NOT_FOUND", "Artifact not found");
          return;
        }
        sendResOk(ws, id, { ok: true });
        broadcastEvent(state, "artifacts.updated", { projectId, artifact: deleted, change: "deleted" });
        return;
      }
      case "workspace.bootstrap.get": {
        const projectId = normalizeId(params.projectId);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        const files = await getBootstrapFiles(state, projectId);
        sendResOk(ws, id, { files });
        return;
      }
      case "workspace.bootstrap.update": {
        const projectId = normalizeId(params.projectId);
        const name = String(params.name ?? "");
        const content = String(params.content ?? "");
        if (!projectId || !name) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or name");
          return;
        }
        const ok = await updateBootstrapFile(state, projectId, name, content);
        if (!ok) {
          sendResError(ws, id, "NOT_FOUND", "Project not found");
          return;
        }
        sendResOk(ws, id, { ok: true });
        return;
      }
      case "workspace.directories.list": {
        const inputPath = normalizeOptionalString(params.path) ?? process.cwd();
        const includeHidden = Boolean(params.includeHidden ?? false);
        const limit = clampWorkspaceListLimit(params.limit);
        try {
          const result = await listWorkspaceDirectories(inputPath, {
            includeHidden,
            limit,
          });
          sendResOk(ws, id, {
            path: result.path,
            entries: result.entries.map((entry) => ({
              name: entry.name,
              path: entry.path,
            })),
            truncated: result.truncated,
          });
        } catch (error) {
          sendResError(ws, id, "BAD_REQUEST", error instanceof Error ? error.message : "Unable to list directories");
        }
        return;
      }
      case "workspace.directories.resolve": {
        const inputPath = normalizeOptionalString(params.path);
        if (!inputPath) {
          sendResError(ws, id, "BAD_REQUEST", "Missing path");
          return;
        }
        try {
          const resolved = await resolveWorkspaceDirectory(inputPath);
          sendResOk(ws, id, {
            path: resolved.path,
            name: resolved.name,
            parentPath: resolved.parentPath,
          });
        } catch (error) {
          sendResError(ws, id, "BAD_REQUEST", error instanceof Error ? error.message : "Unable to resolve directory");
        }
        return;
      }
      case "workspace.list": {
        const projectId = normalizeId(params.projectId);
        const inputPath = normalizeOptionalString(params.path) ?? ".";
        const recursive = params.recursive == null ? true : Boolean(params.recursive);
        const includeHidden = Boolean(params.includeHidden ?? false);
        const limit = clampWorkspaceListLimit(params.limit);
        if (!projectId) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId");
          return;
        }
        await ensureBootstrapDefaults(state, projectId).catch(() => {
          // best effort bootstrap defaults
        });
        await assertWorkspaceRuntimeReady(state, projectId);
        await reconcileAgentsFromHpc(state, projectId, "workspace.list").catch(() => {
          // best effort reconcile
        });
        const response = await callNode(state, "runtime.fs.list", {
          projectId,
          path: inputPath,
          recursive,
          includeHidden,
          limit,
        });
        const entries = normalizeWorkspaceEntries((response as any)?.entries).filter((entry) => !isUploadsWorkspacePath(entry.path));
        sendResOk(ws, id, { entries });
        return;
      }
      case "workspace.content": {
        const projectId = normalizeId(params.projectId);
        const inputPath = normalizeRelativePath(String(params.path ?? ""));
        const offset = Number.isFinite(Number(params.offset)) ? Math.max(0, Math.floor(Number(params.offset))) : 0;
        const length = Number.isFinite(Number(params.length)) ? Math.max(1, Math.floor(Number(params.length))) : 512 * 1024;
        if (!projectId || !inputPath) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or path");
          return;
        }
        if (isUploadsWorkspacePath(inputPath)) {
          sendResError(ws, id, "FORBIDDEN", "uploads/ files are not exposed in workspace view");
          return;
        }
        await assertWorkspaceRuntimeReady(state, projectId);
        if (isAgentsPath(inputPath)) {
          await reconcileAgentsFromHpc(state, projectId, "workspace.content").catch(() => {
            // best effort reconcile
          });
        }
        const result = await callNode(state, "runtime.fs.read", {
          projectId,
          path: inputPath,
          offset,
          length,
          encoding: "utf8",
        });
        sendResOk(ws, id, {
          path: normalizeRelativePath(String((result as any).path ?? inputPath)) ?? inputPath,
          data: typeof (result as any).data === "string" ? (result as any).data : "",
          eof: Boolean((result as any).eof),
          encoding: "utf8",
        });
        return;
      }
      case "workspace.raw": {
        const projectId = normalizeId(params.projectId);
        const inputPath = normalizeRelativePath(String(params.path ?? ""));
        if (!projectId || !inputPath) {
          sendResError(ws, id, "BAD_REQUEST", "Missing projectId or path");
          return;
        }
        if (isUploadsWorkspacePath(inputPath)) {
          sendResError(ws, id, "FORBIDDEN", "uploads/ files are not exposed in workspace view");
          return;
        }
        await assertWorkspaceRuntimeReady(state, projectId);
        if (isAgentsPath(inputPath)) {
          await reconcileAgentsFromHpc(state, projectId, "workspace.raw").catch(() => {
            // best effort reconcile
          });
        }

        const maxBytes = 10 * 1024 * 1024;
        const chunkBytes = 256 * 1024;
        const buffers: Buffer[] = [];
        let offset = 0;
        let total = 0;
        let eof = false;

        while (!eof) {
          const result = await callNode(state, "runtime.fs.read", {
            projectId,
            path: inputPath,
            offset,
            length: chunkBytes,
            encoding: "base64",
          });
          const chunkBase64 = String((result as any).data ?? "");
          eof = Boolean((result as any).eof);
          if (!chunkBase64) break;
          const chunk = Buffer.from(chunkBase64, "base64");
          if (chunk.length === 0) break;
          total += chunk.length;
          if (total > maxBytes) {
            sendResError(ws, id, "BAD_REQUEST", "workspace.raw exceeds max preview size (10 MB)");
            return;
          }
          buffers.push(chunk);
          offset += chunk.length;
          if (eof) break;
        }

        const data = Buffer.concat(buffers).toString("base64");
        sendResOk(ws, id, {
          path: inputPath,
          data,
          encoding: "base64",
          sizeBytes: total,
          eof,
        });
        return;
      }
      case "settings.openai.get": {
        const status = readOpenAISettingsStatus(state.config);
        sendResOk(ws, id, status);
        return;
      }
      case "settings.openai.set": {
        const hasApiKey = Object.prototype.hasOwnProperty.call(params, "apiKey");
        const hasOcrModel = Object.prototype.hasOwnProperty.call(params, "ocrModel");
        const clear = Boolean(params.clear ?? false);
        const source = normalizeOptionalString(params.source) ?? "epoch-app";
        if (!hasApiKey && !hasOcrModel && !clear) {
          sendResError(ws, id, "BAD_REQUEST", "settings.openai.set requires apiKey, ocrModel, or clear=true");
          return;
        }
        const hadOpenAIKey = Boolean(resolveOpenAIApiKeyFromConfig(state.config));
        const apiKey = hasApiKey ? normalizeOptionalString(params.apiKey) : undefined;
        const ocrModel = hasOcrModel ? normalizeOptionalString(params.ocrModel) : undefined;
        await updateOpenAISettings(state, {
          hasApiKey,
          apiKey: clear ? null : apiKey,
          clear,
          ocrModel,
          hasOcrModel,
          source,
        });
        const status = readOpenAISettingsStatus(state.config);
        const openAIKeyJustConfigured = !hadOpenAIKey && status.configured;
        if (openAIKeyJustConfigured) {
          void runHighQualityOcrReindexSweep(state, "settings.openai.set").catch(() => {
            // best effort
          });
        }
        sendResOk(ws, id, status);
        broadcastEvent(state, "settings.openai.updated", {
          configured: status.configured,
          updatedAt: status.updatedAt,
          source: status.source,
          ocrModel: status.ocrModel,
          ts: new Date().toISOString(),
        });
        return;
      }
      default:
        sendResError(ws, id, "BAD_REQUEST", `Unknown method: ${method}`);
        return;
    }
  } catch (err: any) {
    const classified = classifyGatewayError(err);
    sendResError(ws, id, classified.code, classified.message);
  }
}

async function listProjects(state: HubState) {
  const res = await state.pool.query(
    `SELECT id, name, created_at, updated_at, backend_engine,
            codex_model_provider, codex_model_id, codex_approval_policy,
            codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     ORDER BY updated_at DESC`
  );
  return res.rows.map((r: any) => ({
    id: r.id,
    name: r.name,
    createdAt: toIso(r.created_at),
    updatedAt: toIso(r.updated_at),
    backendEngine: normalizeCodexEngine(r.backend_engine) ?? "codex-app-server",
    codexModelProvider: normalizeOptionalString(r.codex_model_provider),
    codexModel: normalizeOptionalString(r.codex_model_id),
    codexApprovalPolicy: normalizeOptionalString(r.codex_approval_policy),
    codexSandbox: safeJsonObject(r.codex_sandbox_json),
    hpcWorkspacePath: normalizeOptionalString(r.hpc_workspace_path),
    hpcWorkspaceState: normalizeOptionalString(r.hpc_workspace_state) ?? "ready",
  }));
}

async function createProject(state: HubState, name: string, requestedWorkspacePath?: string) {
  const id = uuidv4();
  const now = new Date().toISOString();
  const backendEngine = normalizeCodexEngine(process.env.EPOCH_CODEX_DEFAULT_ENGINE) ?? "codex-app-server";
  const workspacePath = resolveProjectWorkspacePath(state, id, requestedWorkspacePath);
  await state.pool.query(
    `INSERT INTO projects (
       id, name, created_at, updated_at,
       backend_engine, codex_model_provider, codex_model_id,
       codex_approval_policy, codex_sandbox_json,
       hpc_workspace_path, hpc_workspace_state
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
    [id, name, now, now, backendEngine, null, null, "on-request", null, workspacePath, "ready"]
  );
  await ensureProjectDirs(state, id);
  await ensureBootstrapDefaults(state, id);
  await state.localRuntime.callNode("workspace.project.ensure", { projectId: id, workspacePath });
  return {
    id,
    name,
    createdAt: now,
    updatedAt: now,
    backendEngine,
    codexModelProvider: null,
    codexModel: null,
    codexApprovalPolicy: "on-request",
    codexSandbox: null,
    hpcWorkspacePath: workspacePath,
    hpcWorkspaceState: "ready",
  };
}

async function renameProject(state: HubState, projectId: string, name: string) {
  const now = new Date().toISOString();
  const res = await state.pool.query(
    "UPDATE projects SET name=$1, updated_at=$2 WHERE id=$3 RETURNING id, name, created_at, updated_at",
    [name, now, projectId]
  );
  if (res.rows.length === 0) return null;
  const r: any = res.rows[0];
  return { id: r.id, name: r.name, createdAt: toIso(r.created_at), updatedAt: toIso(r.updated_at) };
}

async function updateProject(
  state: HubState,
  projectId: string,
  patch: {
    codexApprovalPolicy?: string | null;
    codexSandboxJson?: string | null;
  }
) {
  const updates: string[] = [];
  const args: any[] = [];
  let idx = 1;

  if (Object.prototype.hasOwnProperty.call(patch, "codexApprovalPolicy")) {
    updates.push(`codex_approval_policy=$${idx++}`);
    args.push(patch.codexApprovalPolicy ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexSandboxJson")) {
    updates.push(`codex_sandbox_json=$${idx++}`);
    args.push(patch.codexSandboxJson ?? null);
  }
  updates.push(`updated_at=$${idx++}`);
  args.push(new Date().toISOString());
  args.push(projectId);

  const res = await state.pool.query(
    `UPDATE projects
     SET ${updates.join(", ")}
     WHERE id=$${idx}
     RETURNING id, name, created_at, updated_at, backend_engine,
               codex_model_provider, codex_model_id, codex_approval_policy,
               codex_sandbox_json, hpc_workspace_path, hpc_workspace_state`,
    args
  );
  if (res.rows.length === 0) return null;
  const r: any = res.rows[0];
  return {
    id: r.id,
    name: r.name,
    createdAt: toIso(r.created_at),
    updatedAt: toIso(r.updated_at),
    backendEngine: normalizeCodexEngine(r.backend_engine) ?? "codex-app-server",
    codexModelProvider: normalizeOptionalString(r.codex_model_provider),
    codexModel: normalizeOptionalString(r.codex_model_id),
    codexApprovalPolicy: normalizeOptionalString(r.codex_approval_policy),
    codexSandbox: safeJsonObject(r.codex_sandbox_json),
    hpcWorkspacePath: normalizeOptionalString(r.hpc_workspace_path),
    hpcWorkspaceState: normalizeOptionalString(r.hpc_workspace_state) ?? "ready",
  };
}

async function deleteProject(state: HubState, projectId: string) {
  const existing = await state.pool.query(
    `SELECT id, name, created_at, updated_at, backend_engine,
            codex_model_provider, codex_model_id, codex_approval_policy,
            codex_sandbox_json, hpc_workspace_path, hpc_workspace_state
     FROM projects
     WHERE id=$1`,
    [projectId]
  );
  if (existing.rows.length === 0) return null;
  const row: any = existing.rows[0];

  const res = await state.pool.query("DELETE FROM projects WHERE id=$1", [projectId]);
  if (res.rowCount === 0) return null;
  await rm(projectDir(state, projectId), { recursive: true, force: true });
  return {
    id: row.id,
    name: row.name,
    createdAt: toIso(row.created_at),
    updatedAt: toIso(row.updated_at),
    backendEngine: normalizeCodexEngine(row.backend_engine) ?? "codex-app-server",
    codexModelProvider: normalizeOptionalString(row.codex_model_provider),
    codexModel: normalizeOptionalString(row.codex_model_id),
    codexApprovalPolicy: normalizeOptionalString(row.codex_approval_policy),
    codexSandbox: safeJsonObject(row.codex_sandbox_json),
    hpcWorkspacePath: normalizeOptionalString(row.hpc_workspace_path),
    hpcWorkspaceState: normalizeOptionalString(row.hpc_workspace_state) ?? "ready",
  };
}

async function listSessions(state: HubState, projectId: string, opts: { includeArchived: boolean }) {
  const sql = opts.includeArchived
    ? "SELECT * FROM sessions WHERE project_id=$1 ORDER BY updated_at DESC"
    : "SELECT * FROM sessions WHERE project_id=$1 AND lifecycle='active' ORDER BY updated_at DESC";
  const res = await state.pool.query(sql, [projectId]);
  return res.rows.map((r: any) => ({
    id: r.id,
    projectID: r.project_id,
    title: r.title,
    lifecycle: r.lifecycle,
    createdAt: toIso(r.created_at),
    updatedAt: toIso(r.updated_at),
    backendEngine: normalizeCodexEngine(r.backend_engine) ?? "codex-app-server",
    codexThreadId: normalizeOptionalString(r.codex_thread_id),
    codexModel: normalizeOptionalString(r.codex_model),
    codexModelProvider: normalizeOptionalString(r.codex_model_provider),
    codexApprovalPolicy: normalizeOptionalString(r.codex_approval_policy),
    codexSandbox: safeJsonObject(r.codex_sandbox_json),
    hpcWorkspaceState: normalizeOptionalString(r.hpc_workspace_state),
  }));
}

async function createSession(state: HubState, projectId: string, titleRaw: string | null) {
  const project = await state.pool.query<any>(
    `SELECT id, backend_engine, codex_model_provider, codex_model_id, codex_approval_policy, codex_sandbox_json, hpc_workspace_state
     FROM projects
     WHERE id=$1`,
    [projectId]
  );
  if (project.rows.length === 0) return null;
  const projectRow = project.rows[0] as any;

  const countRes = await state.pool.query<{ count: string }>("SELECT COUNT(1) as count FROM sessions WHERE project_id=$1", [projectId]);
  const count = Number(countRes.rows[0]?.count ?? "0");

  const id = uuidv4();
  const title = titleRaw?.trim() ? titleRaw.trim() : `Session ${count + 1}`;
  const now = new Date().toISOString();
  await state.pool.query(
    `INSERT INTO sessions (
       id, project_id, title, lifecycle, created_at, updated_at,
       backend_engine, codex_thread_id, codex_model, codex_model_provider,
       codex_approval_policy, codex_sandbox_json, hpc_workspace_state
     ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
    [
      id,
      projectId,
      title,
      "active",
      now,
      now,
      normalizeCodexEngine(projectRow.backend_engine) ?? "codex-app-server",
      null,
      normalizeOptionalString(projectRow.codex_model_id),
      normalizeOptionalString(projectRow.codex_model_provider),
      normalizeOptionalString(projectRow.codex_approval_policy) ?? "on-request",
      projectRow.codex_sandbox_json ?? null,
      normalizeOptionalString(projectRow.hpc_workspace_state),
    ]
  );
  await ensureProjectDirs(state, projectId);
  await appendTranscriptLine(state, projectId, id, {
    type: "session.created",
    ts: now,
    sessionId: id,
  });
  // ensure transcript exists
  await mkdir(projectSessionsDir(state, projectId), { recursive: true });
  await appendFile(sessionTranscriptPath(state, projectId, id), "", "utf8");
  return {
    id,
    projectID: projectId,
    title,
    lifecycle: "active",
    createdAt: now,
    updatedAt: now,
    backendEngine: normalizeCodexEngine(projectRow.backend_engine) ?? "codex-app-server",
    codexThreadId: null,
    codexModel: normalizeOptionalString(projectRow.codex_model_id),
    codexModelProvider: normalizeOptionalString(projectRow.codex_model_provider),
    codexApprovalPolicy: normalizeOptionalString(projectRow.codex_approval_policy) ?? "on-request",
    codexSandbox: safeJsonObject(projectRow.codex_sandbox_json),
    hpcWorkspaceState: normalizeOptionalString(projectRow.hpc_workspace_state),
  };
}

async function updateSession(
  state: HubState,
  projectId: string,
  sessionId: string,
  patch: {
    title?: string;
    lifecycle?: string;
    backendEngine?: "codex-app-server";
    codexModel?: string | null;
    codexModelProvider?: string | null;
    codexApprovalPolicy?: string | null;
    codexSandboxJson?: string | null;
  }
) {
  const updates: string[] = [];
  const args: any[] = [];
  let idx = 1;
  if (patch.title && patch.title.trim()) {
    updates.push(`title=$${idx++}`);
    args.push(patch.title.trim());
  }
  if (patch.lifecycle === "active" || patch.lifecycle === "archived") {
    updates.push(`lifecycle=$${idx++}`);
    args.push(patch.lifecycle);
  }
  if (patch.backendEngine === "codex-app-server") {
    updates.push(`backend_engine=$${idx++}`);
    args.push(patch.backendEngine);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexModel")) {
    updates.push(`codex_model=$${idx++}`);
    args.push(patch.codexModel ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexModelProvider")) {
    updates.push(`codex_model_provider=$${idx++}`);
    args.push(patch.codexModelProvider ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexApprovalPolicy")) {
    updates.push(`codex_approval_policy=$${idx++}`);
    args.push(patch.codexApprovalPolicy ?? null);
  }
  if (Object.prototype.hasOwnProperty.call(patch, "codexSandboxJson")) {
    updates.push(`codex_sandbox_json=$${idx++}`);
    args.push(patch.codexSandboxJson ?? null);
  }
  updates.push(`updated_at=$${idx++}`);
  args.push(new Date().toISOString());
  args.push(projectId);
  args.push(sessionId);

  const res = await state.pool.query(
    `UPDATE sessions SET ${updates.join(", ")} WHERE project_id=$${idx++} AND id=$${idx} RETURNING *`,
    args
  );
  if (res.rows.length === 0) return null;
  const r: any = res.rows[0];
  return {
    id: r.id,
    projectID: r.project_id,
    title: r.title,
    lifecycle: r.lifecycle,
    createdAt: toIso(r.created_at),
    updatedAt: toIso(r.updated_at),
    backendEngine: normalizeCodexEngine(r.backend_engine) ?? "codex-app-server",
    codexThreadId: normalizeOptionalString(r.codex_thread_id),
    codexModel: normalizeOptionalString(r.codex_model),
    codexModelProvider: normalizeOptionalString(r.codex_model_provider),
    codexApprovalPolicy: normalizeOptionalString(r.codex_approval_policy),
    codexSandbox: safeJsonObject(r.codex_sandbox_json),
    hpcWorkspaceState: normalizeOptionalString(r.hpc_workspace_state),
  };
}

async function setSessionPermissionLevel(
  state: HubState,
  projectId: string,
  sessionId: string,
  level: "default" | "full",
  _deviceId: string
) {
  const res = await state.pool.query("UPDATE sessions SET permission_level=$1 WHERE project_id=$2 AND id=$3", [level, projectId, sessionId]);
  return res.rowCount > 0;
}

async function getSessionPermissionLevel(state: HubState, projectId: string, sessionId: string): Promise<"default" | "full"> {
  const res = await state.pool.query<any>("SELECT permission_level FROM sessions WHERE project_id=$1 AND id=$2", [projectId, sessionId]);
  const raw = res.rows[0]?.permission_level;
  return normalizePermissionLevel(raw) ?? "default";
}

type RuntimePolicy = {
  exec?: {
    maxTimeoutMs?: number;
    maxConcurrent?: number;
  };
  slurm?: {
    maxTimeMinutes?: number;
    maxCpus?: number;
    maxMemMB?: number;
    maxGpus?: number;
    maxConcurrent?: number;
  };
};

async function getProjectRuntimePolicy(
  state: HubState,
  projectId: string
): Promise<RuntimePolicy | null> {
  const res = await state.pool.query<any>(
    `SELECT codex_sandbox_json
     FROM projects
     WHERE id=$1
     LIMIT 1`,
    [projectId]
  );
  const rawSandbox = res.rows[0]?.codex_sandbox_json;
  const sandbox = safeJsonObject(rawSandbox);
  const runtimePolicyRoot =
    sandbox && typeof sandbox.runtimePolicy === "object" && sandbox.runtimePolicy && !Array.isArray(sandbox.runtimePolicy)
      ? (sandbox.runtimePolicy as Record<string, unknown>)
      : null;
  if (!runtimePolicyRoot) return null;

  const execRaw =
    runtimePolicyRoot.exec && typeof runtimePolicyRoot.exec === "object" && !Array.isArray(runtimePolicyRoot.exec)
      ? (runtimePolicyRoot.exec as Record<string, unknown>)
      : null;
  const slurmRaw =
    runtimePolicyRoot.slurm && typeof runtimePolicyRoot.slurm === "object" && !Array.isArray(runtimePolicyRoot.slurm)
      ? (runtimePolicyRoot.slurm as Record<string, unknown>)
      : null;

  const normalizePositive = (value: unknown) => {
    const parsed = typeof value === "number" ? value : Number(value);
    if (!Number.isFinite(parsed)) return null;
    const next = Math.floor(parsed);
    return next > 0 ? next : null;
  };
  const normalizeNonNegative = (value: unknown) => {
    const parsed = typeof value === "number" ? value : Number(value);
    if (!Number.isFinite(parsed)) return null;
    const next = Math.floor(parsed);
    return next >= 0 ? next : null;
  };

  const exec: RuntimePolicy["exec"] = {};
  if (execRaw) {
    const maxTimeoutMs = normalizePositive(execRaw.maxTimeoutMs);
    const maxConcurrent = normalizePositive(execRaw.maxConcurrent);
    if (maxTimeoutMs != null) exec.maxTimeoutMs = maxTimeoutMs;
    if (maxConcurrent != null) exec.maxConcurrent = maxConcurrent;
  }

  const slurm: RuntimePolicy["slurm"] = {};
  if (slurmRaw) {
    const maxTimeMinutes = normalizePositive(slurmRaw.maxTimeMinutes);
    const maxCpus = normalizePositive(slurmRaw.maxCpus);
    const maxMemMB = normalizePositive(slurmRaw.maxMemMB);
    const maxGpus = normalizeNonNegative(slurmRaw.maxGpus);
    const maxConcurrent = normalizePositive(slurmRaw.maxConcurrent);
    if (maxTimeMinutes != null) slurm.maxTimeMinutes = maxTimeMinutes;
    if (maxCpus != null) slurm.maxCpus = maxCpus;
    if (maxMemMB != null) slurm.maxMemMB = maxMemMB;
    if (maxGpus != null) slurm.maxGpus = maxGpus;
    if (maxConcurrent != null) slurm.maxConcurrent = maxConcurrent;
  }

  const hasExec = Object.keys(exec).length > 0;
  const hasSlurm = Object.keys(slurm).length > 0;
  if (!hasExec && !hasSlurm) return null;

  return {
    ...(hasExec ? { exec } : {}),
    ...(hasSlurm ? { slurm } : {}),
  };
}

async function insertSessionPermissionEvent(
  state: HubState,
  args: {
    id: string;
    projectId: string;
    sessionId: string;
    level: "default" | "full";
    previousLevel: "default" | "full";
    changedByDeviceId: string;
  }
) {
  await state.pool.query(
    `INSERT INTO session_permission_events (
       id, project_id, session_id, level, previous_level, changed_by_device_id, created_at
     ) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [args.id, args.projectId, args.sessionId, args.level, args.previousLevel, args.changedByDeviceId, new Date().toISOString()]
  );
}

async function appendPermissionChangeCodexItem(
  state: HubState,
  args: {
    projectId: string;
    sessionId: string;
    previousLevel: "default" | "full";
    level: "default" | "full";
    changedByDeviceId: string;
  }
) {
  const sessionRes = await state.pool.query<any>(
    `SELECT codex_thread_id
     FROM sessions
     WHERE project_id=$1 AND id=$2
     LIMIT 1`,
    [args.projectId, args.sessionId]
  );
  const threadId = normalizeOptionalString(sessionRes.rows[0]?.codex_thread_id);
  if (!threadId) return;

  const threadRes = await state.pool.query<any>("SELECT id FROM threads WHERE id=$1 LIMIT 1", [threadId]);
  if (threadRes.rows.length === 0) return;

  const nowIso = new Date().toISOString();
  const nowSec = Math.floor(Date.now() / 1000);
  const suffix = `permission_${Date.now()}_${Math.floor(Math.random() * 1_000_000)}`;
  const turnRawId = suffix;
  const itemRawId = `${suffix}_item`;
  const turnId = `${threadId}::turn::${turnRawId}`;
  const itemId = `${threadId}::item::${itemRawId}`;
  const text = `Permission changed: ${args.previousLevel} -> ${args.level}`;

  const itemPayload = {
    type: "permissionChange",
    id: itemRawId,
    previousLevel: args.previousLevel,
    level: args.level,
    changedByDeviceId: args.changedByDeviceId,
    changedAt: nowIso,
    text,
  };

  await state.pool.query(
    `INSERT INTO turns (id, thread_id, status, error_json, created_at, completed_at)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [turnId, threadId, "completed", null, nowSec, nowSec]
  );

  await state.pool.query(
    `INSERT INTO items (id, thread_id, turn_id, type, payload_json, created_at, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [itemId, threadId, turnId, "permissionChange", JSON.stringify(itemPayload), nowSec, nowSec]
  );

  const eventPayloads = [
    {
      method: "turn/started",
      params: {
        threadId,
        turn: {
          id: turnRawId,
          items: [],
          status: "inProgress",
          error: null,
        },
      },
    },
    {
      method: "item/completed",
      params: {
        threadId,
        turnId: turnRawId,
        item: itemPayload,
      },
    },
    {
      method: "turn/completed",
      params: {
        threadId,
        turn: {
          id: turnRawId,
          items: [],
          status: "completed",
          error: null,
        },
      },
    },
  ];

  for (const event of eventPayloads) {
    await state.pool.query(
      `INSERT INTO thread_events (thread_id, event_json, created_at)
       VALUES ($1,$2,$3)`,
      [threadId, JSON.stringify(event), nowSec]
    );
  }

  await state.pool.query(`UPDATE threads SET preview=$1, updated_at=$2 WHERE id=$3`, [preview(text), nowSec, threadId]);
}

async function getSessionContextStats(state: HubState, projectId: string, sessionId: string) {
  const res = await state.pool.query<any>(
    `SELECT permission_level, context_model_id, context_window_tokens, context_used_input_tokens, context_used_tokens, context_updated_at
     FROM sessions WHERE project_id=$1 AND id=$2`,
    [projectId, sessionId]
  );
  const row: any = res.rows[0];
  if (!row) return null;
  const contextWindowTokens = row.context_window_tokens == null ? null : Number(row.context_window_tokens);
  const usedInputTokens = row.context_used_input_tokens == null ? null : Number(row.context_used_input_tokens);
  const usedTokens = row.context_used_tokens == null ? null : Number(row.context_used_tokens);
  return {
    projectId,
    sessionId,
    permissionLevel: typeof row.permission_level === "string" ? row.permission_level : "default",
    modelId: row.context_model_id == null ? null : String(row.context_model_id),
    contextWindowTokens,
    usedInputTokens,
    usedTokens,
    remainingTokens:
      typeof contextWindowTokens === "number" && typeof usedInputTokens === "number"
        ? Math.max(0, Math.max(1, Math.floor(contextWindowTokens)) - Math.max(0, Math.floor(usedInputTokens)))
        : typeof contextWindowTokens === "number" && typeof usedTokens === "number"
          ? Math.max(0, Math.max(1, Math.floor(contextWindowTokens)) - Math.max(0, Math.floor(usedTokens)))
        : null,
    updatedAt: row.context_updated_at == null ? null : String(row.context_updated_at),
  };
}

async function persistSessionContextStats(state: HubState, stats: {
  projectId: string;
  sessionId: string;
  modelId: string;
  contextWindowTokens: number;
  usedInputTokens: number;
  usedTokens: number;
}) {
  const now = new Date().toISOString();
  const contextWindowTokens = Math.max(1, Math.floor(stats.contextWindowTokens));
  const usedInputTokens = Math.max(0, Math.floor(stats.usedInputTokens));
  const usedTokens = Math.max(0, Math.floor(stats.usedTokens));

  await state.pool.query(
    `UPDATE sessions SET
       context_model_id=$1,
       context_window_tokens=$2,
       context_used_input_tokens=$3,
       context_used_tokens=$4,
       context_updated_at=$5
     WHERE project_id=$6 AND id=$7`,
    [
      stats.modelId,
      contextWindowTokens,
      usedInputTokens,
      usedTokens,
      now,
      stats.projectId,
      stats.sessionId,
    ]
  );

  broadcastEvent(state, "sessions.context.updated", {
    projectId: stats.projectId,
    sessionId: stats.sessionId,
    modelId: stats.modelId,
    contextWindowTokens,
    usedInputTokens,
    usedTokens,
    remainingTokens: Math.max(0, contextWindowTokens - usedInputTokens),
    updatedAt: now,
  });
}

async function deleteSession(state: HubState, projectId: string, sessionId: string) {
  const existing = await state.pool.query("SELECT * FROM sessions WHERE project_id=$1 AND id=$2", [projectId, sessionId]);
  if (existing.rows.length === 0) return null;
  const r: any = existing.rows[0];
  const mappedThreads = await state.pool.query<any>("SELECT id FROM threads WHERE session_id=$1", [sessionId]);
  const deletedSession = {
    id: r.id,
    projectID: r.project_id,
    title: r.title,
    lifecycle: r.lifecycle,
    createdAt: toIso(r.created_at),
    updatedAt: toIso(r.updated_at),
    backendEngine: normalizeCodexEngine(r.backend_engine) ?? "codex-app-server",
    codexThreadId: normalizeOptionalString(r.codex_thread_id),
    codexModel: normalizeOptionalString(r.codex_model),
    codexModelProvider: normalizeOptionalString(r.codex_model_provider),
    codexApprovalPolicy: normalizeOptionalString(r.codex_approval_policy),
    codexSandbox: safeJsonObject(r.codex_sandbox_json),
    hpcWorkspaceState: normalizeOptionalString(r.hpc_workspace_state),
  };

  // detach runs from deleted session
  await state.pool.query("UPDATE runs SET session_id=NULL WHERE project_id=$1 AND session_id=$2", [projectId, sessionId]);

  const res = await state.pool.query("DELETE FROM sessions WHERE project_id=$1 AND id=$2", [projectId, sessionId]);
  if (res.rowCount === 0) return null;
  for (const row of mappedThreads.rows) {
    const threadId = String((row as any).id ?? "");
    if (!threadId) continue;
    await rm(threadTranscriptPath(state, { projectId, threadId }), { force: true });
  }
  await rm(sessionTranscriptPath(state, projectId, sessionId), { force: true });
  return deletedSession;
}

async function listMessages(state: HubState, projectId: string, sessionId: string, opts: { beforeTs: string | null; limit: number }) {
  const args: any[] = [projectId, sessionId];
  let where = "project_id=$1 AND session_id=$2";
  if (opts.beforeTs) {
    args.push(opts.beforeTs);
    where += ` AND ts < $${args.length}`;
  }
  args.push(opts.limit);
  const sql = `SELECT * FROM messages WHERE ${where} ORDER BY ts DESC LIMIT $${args.length}`;
  const res = await state.pool.query(sql, args);
  const rows = res.rows.reverse();
  return rows.map((r: any) => ({
    id: r.id,
    sessionID: r.session_id,
    role: r.role,
    text: r.content,
    createdAt: toIso(r.ts),
    artifactRefs: sanitizeArtifactRefsForTransport(parseJson(r.artifact_refs, [])),
    proposedPlan: parseJson(r.proposed_plan, null),
    runID: r.run_id ?? null,
    parentID: r.parent_id ?? null,
  }));
}

type NormalizedAttachmentRef = {
  displayText: string;
  projectID: string;
  path: string;
  artifactID: string | null;
  scope: string;
  mimeType: string | null;
  sourceName: string;
  inlineDataBase64?: string;
  byteCount?: number;
};

const MAX_INLINE_ATTACHMENT_BYTES = 8 * 1024 * 1024;

export function normalizeSessionAttachmentsForChatSend(raw: unknown, projectId: string): {
  attachmentRefs: NormalizedAttachmentRef[];
  promptImages: Array<{ type: "image"; mimeType: string; data: string }>;
} {
  if (!projectId || !Array.isArray(raw)) {
    return {
      attachmentRefs: [],
      promptImages: [],
    };
  }
  const refs: NormalizedAttachmentRef[] = [];
  const promptImages: Array<{ type: "image"; mimeType: string; data: string }> = [];

  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const name = String((item as any).name ?? "").trim();
    const pathValue = String((item as any).path ?? "").trim();
    if (!name || !pathValue) continue;
    const scopeRaw = String((item as any).scope ?? "session").trim().toLowerCase();
    const scope = scopeRaw === "project" ? "project" : "session";
    const idRaw = String((item as any).id ?? "").trim();
    const mimeType = String((item as any).mimeType ?? "").trim();
    const inlineDataBase64Raw = String((item as any).inlineDataBase64 ?? "").trim().replace(/\s+/g, "");
    const inlineDataBase64 = inlineDataBase64Raw || null;
    const approxBytes = inlineDataBase64 ? base64ByteLength(inlineDataBase64) : 0;
    const byteCountRaw = Number((item as any).byteCount);
    const byteCount = Number.isFinite(byteCountRaw) && byteCountRaw > 0
      ? Math.max(1, Math.floor(byteCountRaw))
      : (approxBytes > 0 ? approxBytes : null);
    const inlineWithinLimit = Boolean(inlineDataBase64 && approxBytes > 0 && approxBytes <= MAX_INLINE_ATTACHMENT_BYTES);

    const ref: NormalizedAttachmentRef = {
      displayText: name,
      projectID: projectId,
      path: pathValue,
      artifactID: idRaw || null,
      scope,
      mimeType: mimeType || null,
      sourceName: name,
    };
    if (inlineWithinLimit && inlineDataBase64) {
      ref.inlineDataBase64 = inlineDataBase64;
    }
    if (byteCount != null) {
      ref.byteCount = byteCount;
    }
    refs.push(ref);

    if (scope !== "session") continue;
    const normalizedMime = (mimeType || inferAttachmentMimeTypeFromName(name) || "").toLowerCase();
    if (!normalizedMime.startsWith("image/")) continue;
    if (!inlineWithinLimit || !inlineDataBase64) continue;

    promptImages.push({
      type: "image",
      mimeType: normalizedMime,
      data: inlineDataBase64,
    });
  }

  return {
    attachmentRefs: refs,
    promptImages,
  };
}

function normalizeAttachmentLookupKey(ref: {
  path?: string | null;
  displayText?: string | null;
  sourceName?: string | null;
}) {
  const pathValue = String(ref.path ?? "").trim();
  const label = String(ref.displayText ?? ref.sourceName ?? "").trim();
  if (!pathValue && !label) return "";
  return `${pathValue.toLowerCase()}\u0000${label.toLowerCase()}`;
}

function normalizeAttachmentRefForMerge(raw: unknown): NormalizedAttachmentRef | null {
  if (!raw || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  const displayText = String(obj.displayText ?? "").trim();
  const projectID = String(obj.projectID ?? "").trim();
  const pathValue = String(obj.path ?? "").trim();
  if (!displayText || !projectID || !pathValue) return null;
  const artifactIDRaw = String(obj.artifactID ?? "").trim();
  const scopeRaw = String(obj.scope ?? "session").trim().toLowerCase();
  const mimeType = String(obj.mimeType ?? "").trim();
  const sourceName = String(obj.sourceName ?? displayText).trim() || displayText;
  const inlineDataBase64 = String(obj.inlineDataBase64 ?? "").trim().replace(/\s+/g, "");
  const byteCountRaw = Number(obj.byteCount);

  const ref: NormalizedAttachmentRef = {
    displayText,
    projectID,
    path: pathValue,
    artifactID: artifactIDRaw || null,
    scope: scopeRaw === "project" ? "project" : "session",
    mimeType: mimeType || null,
    sourceName,
  };
  if (inlineDataBase64) {
    ref.inlineDataBase64 = inlineDataBase64;
  }
  if (Number.isFinite(byteCountRaw) && byteCountRaw > 0) {
    ref.byteCount = Math.max(1, Math.floor(byteCountRaw));
  }
  return ref;
}

export function mergeAttachmentRefsWithExistingInline(
  incomingRefs: NormalizedAttachmentRef[],
  existingRefsRaw: unknown
): NormalizedAttachmentRef[] {
  const existingRefs = Array.isArray(existingRefsRaw)
    ? existingRefsRaw
      .map((entry) => normalizeAttachmentRefForMerge(entry))
      .filter((entry): entry is NormalizedAttachmentRef => entry != null)
    : [];
  if (existingRefs.length === 0) return incomingRefs;
  if (incomingRefs.length === 0) return existingRefs;

  const existingInlineByArtifactID = new Map<string, NormalizedAttachmentRef>();
  const existingInlineByPathAndName = new Map<string, NormalizedAttachmentRef>();

  for (const ref of existingRefs) {
    const inlineDataBase64 = String(ref.inlineDataBase64 ?? "").trim();
    if (!inlineDataBase64) continue;
    if (ref.artifactID) {
      existingInlineByArtifactID.set(ref.artifactID.toLowerCase(), ref);
    }
    const key = normalizeAttachmentLookupKey(ref);
    if (key) {
      existingInlineByPathAndName.set(key, ref);
    }
  }

  return incomingRefs.map((ref) => {
    if (String(ref.inlineDataBase64 ?? "").trim()) {
      return ref;
    }
    const byArtifactID = ref.artifactID ? existingInlineByArtifactID.get(ref.artifactID.toLowerCase()) : null;
    const byPathAndName = byArtifactID ? null : existingInlineByPathAndName.get(normalizeAttachmentLookupKey(ref));
    const source = byArtifactID ?? byPathAndName;
    if (!source) return ref;

    return {
      ...ref,
      mimeType: ref.mimeType ?? source.mimeType,
      inlineDataBase64: source.inlineDataBase64,
      byteCount: ref.byteCount ?? source.byteCount,
    };
  });
}

export function buildPromptImagesFromAttachmentRefs(
  refs: NormalizedAttachmentRef[]
): Array<{ type: "image"; mimeType: string; data: string }> {
  const images: Array<{ type: "image"; mimeType: string; data: string }> = [];
  for (const ref of refs) {
    const mimeType = (ref.mimeType ?? "").toLowerCase();
    const inlineDataBase64 = String(ref.inlineDataBase64 ?? "").trim();
    if (mimeType.startsWith("image/") && inlineDataBase64) {
      images.push({ type: "image", mimeType, data: inlineDataBase64 });
    }
  }
  return images;
}

function base64ByteLength(value: string): number {
  const normalized = String(value ?? "").trim();
  if (!normalized) return 0;
  const padding = normalized.endsWith("==") ? 2 : normalized.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor((normalized.length * 3) / 4) - padding);
}

function inferAttachmentMimeTypeFromName(name: string): string | null {
  const ext = path.posix.extname(String(name ?? "").toLowerCase());
  switch (ext) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".heic":
      return "image/heic";
    case ".pdf":
      return "application/pdf";
    case ".txt":
      return "text/plain";
    case ".md":
    case ".markdown":
      return "text/markdown";
    case ".json":
      return "application/json";
    case ".csv":
      return "text/csv";
    case ".xml":
      return "application/xml";
    case ".yaml":
    case ".yml":
      return "application/x-yaml";
    default:
      return null;
  }
}

const MAX_INLINE_ATTACHMENT_CONTEXT_FILES = 4;
const MAX_INLINE_ATTACHMENT_CONTEXT_CHARS_PER_FILE = 9000;
const MAX_INLINE_ATTACHMENT_CONTEXT_TOTAL_CHARS = 28000;

export async function buildSessionAttachmentPromptContext(
  refs: Array<{
    displayText: string;
    scope?: string | null;
    mimeType?: string | null;
    inlineDataBase64?: string | null;
  }>
): Promise<string> {
  if (!Array.isArray(refs) || refs.length === 0) return "";

  const sections: string[] = [];
  let totalChars = 0;
  for (const ref of refs) {
    if (sections.length >= MAX_INLINE_ATTACHMENT_CONTEXT_FILES) break;
    if (totalChars >= MAX_INLINE_ATTACHMENT_CONTEXT_TOTAL_CHARS) break;

    if (String(ref.scope ?? "session").toLowerCase() !== "session") continue;

    const name = String(ref.displayText ?? "").trim();
    if (!name) continue;

    const normalizedMime = String(ref.mimeType ?? "").trim().toLowerCase()
      || String(inferAttachmentMimeTypeFromName(name) ?? "").toLowerCase();
    if (normalizedMime.startsWith("image/")) continue;

    const inlineDataBase64 = String(ref.inlineDataBase64 ?? "").trim();
    if (!inlineDataBase64) continue;

    let raw: Buffer;
    try {
      raw = Buffer.from(inlineDataBase64, "base64");
    } catch {
      continue;
    }
    if (!raw.length) continue;

    try {
      const extracted = await extractInlineAttachmentTextForPrompt({
        fileName: name,
        contentType: normalizedMime || null,
        data: raw,
      });
      const clipped = clipAttachmentContextText(extracted.text, MAX_INLINE_ATTACHMENT_CONTEXT_CHARS_PER_FILE);
      if (!clipped) continue;

      const sectionHeader = normalizedMime
        ? `Attachment: ${name} (${normalizedMime})`
        : `Attachment: ${name}`;
      const section = `${sectionHeader}\n${clipped}`;
      if (section.length + totalChars > MAX_INLINE_ATTACHMENT_CONTEXT_TOTAL_CHARS) break;
      sections.push(section);
      totalChars += section.length;
    } catch {
      continue;
    }
  }

  if (sections.length === 0) return "";
  return [
    "",
    "[Session attachment extracted content]",
    "Use the following extracted text from user-attached files when answering:",
    "",
    sections.join("\n\n"),
  ].join("\n");
}

function clipAttachmentContextText(text: string, maxChars: number): string {
  const normalized = String(text ?? "")
    .replace(/\u0000/g, "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  if (!normalized) return "";
  if (normalized.length <= maxChars) return normalized;
  return `${normalized.slice(0, Math.max(0, maxChars - 20)).trimEnd()}\n[...truncated...]`;
}

export function appendAttachmentSummaryToText(
  text: string,
  refs: Array<{ displayText: string; scope?: string | null; mimeType?: string | null }>
) {
  if (!Array.isArray(refs) || refs.length === 0) {
    return text;
  }
  const seen = new Set<string>();
  const items: Array<{ name: string; mimeType: string }> = [];
  for (const ref of refs) {
    const name = String(ref.displayText ?? "").trim();
    const mimeType = String(ref.mimeType ?? "").trim();
    if (!name) continue;
    const key = `${name}\u0000${mimeType}`;
    if (seen.has(key)) continue;
    seen.add(key);
    items.push({ name, mimeType });
    if (items.length >= 12) break;
  }
  if (items.length === 0) {
    return text;
  }
  const bullets = items.map((item) => item.mimeType ? `- ${item.name} (${item.mimeType})` : `- ${item.name}`).join("\n");
  return `${text}\n\n[Session attachments]\n${bullets}`;
}

export function sanitizeArtifactRefsForTransport(
  refsRaw: unknown
): Array<Record<string, unknown>> {
  if (!Array.isArray(refsRaw)) return [];
  return refsRaw.map((ref) => {
    if (!ref || typeof ref !== "object") return ref;
    const next = { ...ref };
    delete (next as any).inlineDataBase64;
    return next;
  });
}

function stripInlineAttachmentPayloadFromRefs(
  refs: Array<Record<string, unknown>>
): Array<Record<string, unknown>> {
  return sanitizeArtifactRefsForTransport(refs);
}

type RewriteSessionRow = {
  id: string;
  ts: string;
  role: string;
  content: string;
  artifact_refs: string | null;
  proposed_plan: string | null;
  run_id: string | null;
  parent_id: string | null;
};

async function getMessageArtifactRefs(
  state: HubState,
  projectId: string,
  sessionId: string,
  messageId: string
): Promise<Array<Record<string, unknown>>> {
  const res = await state.pool.query<{ artifact_refs: string | null }>(
    "SELECT artifact_refs FROM messages WHERE id=$1 AND project_id=$2 AND session_id=$3",
    [messageId, projectId, sessionId]
  );
  if (res.rows.length === 0) return [];
  return parseJson(res.rows[0]?.artifact_refs, []);
}

export function rewriteSessionMessagesForOverwrite(
  rows: RewriteSessionRow[],
  opts: {
    messageId: string;
    text: string;
    artifactRefs: Array<Record<string, unknown>>;
  }
):
  | { ok: false; reason: "target_not_found" | "target_not_user" }
  | {
    ok: true;
    keptRows: RewriteSessionRow[];
    deletedMessageIds: string[];
    updatedMessage: {
      id: string;
      text: string;
      createdAt: string;
      artifactRefs: Array<Record<string, unknown>>;
      runID: string | null;
      parentID: string | null;
    };
  } {
  const ordered = rows.slice().sort((a, b) => {
    const byTs = String(a.ts).localeCompare(String(b.ts));
    if (byTs !== 0) return byTs;
    return String(a.id).localeCompare(String(b.id));
  });
  const index = ordered.findIndex((row) => String(row.id) === opts.messageId);
  if (index === -1) {
    return { ok: false, reason: "target_not_found" };
  }

  const target = ordered[index]!;
  if (String(target.role) !== "user") {
    return { ok: false, reason: "target_not_user" };
  }

  const updatedTarget: RewriteSessionRow = {
    ...target,
    content: opts.text,
    artifact_refs: JSON.stringify(opts.artifactRefs ?? []),
    proposed_plan: null,
  };
  const keptRows = [...ordered.slice(0, index), updatedTarget];
  const deletedMessageIds = ordered.slice(index + 1).map((row) => String(row.id));

  return {
    ok: true,
    keptRows,
    deletedMessageIds,
    updatedMessage: {
      id: String(updatedTarget.id),
      text: opts.text,
      createdAt: toIso(updatedTarget.ts),
      artifactRefs: opts.artifactRefs,
      runID: updatedTarget.run_id ?? null,
      parentID: updatedTarget.parent_id ?? null,
    },
  };
}

async function overwriteUserMessageAndTrimSession(
  state: HubState,
  projectId: string,
  sessionId: string,
  messageId: string,
  text: string,
  artifactRefs: Array<Record<string, unknown>>
): Promise<
  | { ok: true }
  | { ok: false; reason: "session_not_found" | "target_not_found" | "target_not_user" }
> {
  const exists = await state.pool.query("SELECT 1 FROM sessions WHERE id=$1 AND project_id=$2", [sessionId, projectId]);
  if (exists.rows.length === 0) {
    return { ok: false, reason: "session_not_found" };
  }

  const rowsRes = await state.pool.query<RewriteSessionRow>(
    `SELECT id, ts, role, content, artifact_refs, proposed_plan, run_id, parent_id
     FROM messages
     WHERE project_id=$1 AND session_id=$2
     ORDER BY ts ASC, id ASC`,
    [projectId, sessionId]
  );
  const rewrite = rewriteSessionMessagesForOverwrite(rowsRes.rows, {
    messageId,
    text,
    artifactRefs,
  });
  if (!rewrite.ok) {
    return { ok: false, reason: rewrite.reason };
  }

  const now = new Date().toISOString();

  await state.pool.exec("BEGIN");
  try {
    await state.pool.query(
      `UPDATE messages
       SET content=$1, artifact_refs=$2, proposed_plan=$3
       WHERE id=$4 AND project_id=$5 AND session_id=$6`,
      [text, JSON.stringify(artifactRefs), null, messageId, projectId, sessionId]
    );

    if (rewrite.deletedMessageIds.length > 0) {
      const placeholders = rewrite.deletedMessageIds.map((_, idx) => `$${idx + 3}`).join(",");
      await state.pool.query(
        `DELETE FROM messages WHERE project_id=$1 AND session_id=$2 AND id IN (${placeholders})`,
        [projectId, sessionId, ...rewrite.deletedMessageIds]
      );
    }

    await state.pool.query(
      "UPDATE sessions SET updated_at=$1, last_message_preview=$2, last_message_at=$1 WHERE id=$3 AND project_id=$4",
      [now, preview(text), sessionId, projectId]
    );
    await state.pool.exec("COMMIT");
  } catch (error) {
    await state.pool.exec("ROLLBACK");
    throw error;
  }

  const transcriptEntries = rewrite.keptRows.map((row) => ({
    id: String(row.id),
    ts: toIso(row.ts),
    role: String(row.role),
    content: String(row.content ?? ""),
    artifactRefs: stripInlineAttachmentPayloadFromRefs(parseJson(row.artifact_refs, [])),
    proposedPlan: parseJson(row.proposed_plan, null),
    runId: row.run_id ?? null,
    parentId: row.parent_id ?? null,
  }));
  await writeTranscriptEntriesToJsonl(state, projectId, sessionId, transcriptEntries);

  const message = {
    id: rewrite.updatedMessage.id,
    sessionID: sessionId,
    role: "user",
    text: rewrite.updatedMessage.text,
    createdAt: rewrite.updatedMessage.createdAt,
    artifactRefs: sanitizeArtifactRefsForTransport(rewrite.updatedMessage.artifactRefs),
    proposedPlan: null,
    runID: rewrite.updatedMessage.runID,
    parentID: rewrite.updatedMessage.parentID,
  };
  broadcastEvent(state, "chat.message.created", {
    projectId,
    sessionId,
    message,
  });

  return { ok: true };
}

async function persistUserMessage(
  state: HubState,
  projectId: string,
  sessionId: string,
  text: string,
  artifactRefs: Array<Record<string, unknown>> = []
) {
  const exists = await state.pool.query("SELECT 1 FROM sessions WHERE id=$1 AND project_id=$2", [sessionId, projectId]);
  if (exists.rows.length === 0) return false;

  const id = uuidv4();
  const now = new Date().toISOString();
  const message = {
    id,
    sessionID: sessionId,
    role: "user",
    text,
    createdAt: now,
    artifactRefs: sanitizeArtifactRefsForTransport(artifactRefs),
    proposedPlan: null,
  };
  const transcriptArtifactRefs = stripInlineAttachmentPayloadFromRefs(artifactRefs);

  await appendTranscriptLine(state, projectId, sessionId, {
    id,
    ts: now,
    role: "user",
    content: text,
    artifactRefs: transcriptArtifactRefs,
  });

  await state.pool.query(
    `INSERT INTO messages (id, project_id, session_id, ts, role, content, artifact_refs, proposed_plan)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
    [id, projectId, sessionId, now, "user", text, JSON.stringify(artifactRefs), null]
  );

  await state.pool.query(
    "UPDATE sessions SET updated_at=$1, last_message_preview=$2, last_message_at=$1 WHERE id=$3 AND project_id=$4",
    [now, preview(text), sessionId, projectId]
  );

  broadcastEvent(state, "chat.message.created", { projectId, sessionId, message });
  return true;
}

async function updateRun(state: HubState, projectId: string, runId: string, mutator: (row: any) => any) {
  const res = await state.pool.query("SELECT * FROM runs WHERE id=$1 AND project_id=$2", [runId, projectId]);
  if (res.rows.length === 0) return;
  const row: any = res.rows[0];
  const updated = mutator(row);
  const stepTitlesJson = typeof updated.step_titles === "string" ? updated.step_titles : JSON.stringify(updated.step_titles ?? []);
  const producedPathsJson =
    typeof updated.produced_artifact_paths === "string"
      ? updated.produced_artifact_paths
      : JSON.stringify(updated.produced_artifact_paths ?? []);
  await state.pool.query(
    `UPDATE runs SET status=$1, completed_at=$2, current_step=$3, total_steps=$4, log_snippet=$5, step_titles=$6,
       produced_artifact_paths=$7, hpc_job_id=$8 WHERE id=$9 AND project_id=$10`,
    [
      updated.status,
      updated.completed_at,
      updated.current_step,
      updated.total_steps,
      updated.log_snippet,
      stepTitlesJson,
      producedPathsJson,
      updated.hpc_job_id,
      runId,
      projectId,
    ]
  );
}

async function updateRunCurrentStep(
  state: HubState,
  opts: { projectId: string; runId: string; currentStep: number; logSnippet: string }
) {
  await updateRun(state, opts.projectId, opts.runId, (run) => {
    run.status = "running";
    run.current_step = Math.max(0, Math.floor(opts.currentStep));
    run.log_snippet = String(opts.logSnippet ?? "");
    return run;
  });

  const runRecord = await getRun(state, opts.projectId, opts.runId);
  if (!runRecord) return;
  broadcastEvent(state, "runs.updated", { projectId: opts.projectId, run: runRecord, change: "updated" });
}

async function listRuns(state: HubState, projectId: string) {
  const res = await state.pool.query("SELECT * FROM runs WHERE project_id=$1 ORDER BY initiated_at DESC", [projectId]);
  return res.rows.map(mapRunRecord);
}

async function getRun(state: HubState, projectId: string, runId: string) {
  const res = await state.pool.query("SELECT * FROM runs WHERE project_id=$1 AND id=$2", [projectId, runId]);
  if (res.rows.length === 0) return null;
  return mapRunRecord(res.rows[0] as any);
}

function mapRunRecord(r: any) {
  return {
    id: r.id,
    projectID: r.project_id,
    sessionID: r.session_id,
    status: r.status,
    initiatedAt: toIso(r.initiated_at),
    completedAt: r.completed_at ? toIso(r.completed_at) : null,
    currentStep: r.current_step,
    totalSteps: r.total_steps,
    logSnippet: r.log_snippet,
    stepTitles: parseJson(r.step_titles, []),
    producedArtifactPaths: parseJson(r.produced_artifact_paths, []),
    hpcJobId: r.hpc_job_id ?? null,
  };
}

async function listArtifacts(state: HubState, projectId: string, opts: { prefix: string | null }) {
  const args: any[] = [projectId];
  let sql = `
    SELECT
      a.*,
      pfi.status AS index_status,
      pfi.summary AS index_summary,
      pfi.error AS index_error,
      pfi.completed_at AS indexed_at
    FROM artifacts a
    LEFT JOIN project_file_index pfi
      ON pfi.project_id = a.project_id
     AND pfi.artifact_path = a.path
    WHERE a.project_id=$1`;
  if (opts.prefix) {
    args.push(`${opts.prefix}%`);
    sql += ` AND a.path LIKE $${args.length}`;
  }
  sql += " ORDER BY a.path ASC";
  const res = await state.pool.query(sql, args);
  return res.rows.map(mapArtifact);
}

async function getArtifactByPath(state: HubState, projectId: string, artifactPath: string) {
  const res = await state.pool.query(
    `SELECT
       a.*,
       pfi.status AS index_status,
       pfi.summary AS index_summary,
       pfi.error AS index_error,
       pfi.completed_at AS indexed_at
     FROM artifacts a
     LEFT JOIN project_file_index pfi
       ON pfi.project_id = a.project_id
      AND pfi.artifact_path = a.path
     WHERE a.project_id=$1 AND a.path=$2`,
    [projectId, artifactPath]
  );
  if (res.rows.length === 0) return null;
  return mapArtifact(res.rows[0] as any);
}

function mapArtifact(r: any) {
  return {
    id: r.id,
    projectID: r.project_id,
    path: r.path,
    kind: r.kind,
    origin: r.origin,
    modifiedAt: toIso(r.modified_at),
    sizeBytes: r.size_bytes == null ? null : Number(r.size_bytes),
    createdBySessionID: r.created_by_session_id ?? null,
    createdByRunID: r.created_by_run_id ?? null,
    indexStatus: normalizeIndexStatus(r.index_status),
    indexSummary: typeof r.index_summary === "string" ? r.index_summary : null,
    indexError: typeof r.index_error === "string" ? r.index_error : null,
    indexedAt: typeof r.indexed_at === "string" ? toIso(r.indexed_at) : null,
  };
}

async function enqueueUploadIndexing(
  state: HubState,
  input: { projectId: string; artifactPath: string; uploadId: string; storedPath: string; contentType: string | null }
) {
  await queueProjectUploadIndexing(input, {
    pool: state.pool,
    getOpenAIApiKey: () => getApiKeyForProvider(state, "openai"),
    getOpenAIOcrModel: async () => resolveOpenAIOcrModelFromConfig(state.config),
    onStatusChange: async () => {
      broadcastEvent(state, "artifacts.updated", {
        projectId: input.projectId,
        artifact: await getArtifactByPath(state, input.projectId, input.artifactPath),
        change: "updated",
      });
    },
    syncFileToHpc: async (artPath, extractedText, summary) => {
      await syncIndexedUploadToHpc(state, {
        projectId: input.projectId,
        artifactPath: artPath,
        storedPath: input.storedPath,
        extractedText,
        summary,
      });
    },
  });
}

async function syncIndexedUploadToHpc(
  state: HubState,
  args: {
    projectId: string;
    artifactPath: string;
    storedPath: string;
    extractedText: string;
    summary: string;
  }
) {
  if (!state.node) return;
  const textPath = args.artifactPath.replace(/\.[^.]+$/, ".txt");
  const originalData = await readFile(args.storedPath).catch(() => null);
  if (originalData) {
    await callNode(state, "runtime.fs.write", {
      projectId: args.projectId,
      path: `context/${args.artifactPath}`,
      data: originalData.toString("base64"),
      encoding: "base64",
      permissionLevel: "full",
    });
  }

  await callNode(state, "runtime.fs.write", {
    projectId: args.projectId,
    path: `context/${textPath}`,
    data: args.extractedText,
    encoding: "utf8",
    permissionLevel: "full",
  });
  await callNode(state, "runtime.fs.write", {
    projectId: args.projectId,
    path: `context/${textPath}.summary`,
    data: args.summary,
    encoding: "utf8",
    permissionLevel: "full",
  });
}

const OCR_REINDEX_SWEEP_LIMIT = Number.isFinite(Number(process.env.EPOCH_OCR_REINDEX_SWEEP_LIMIT))
  ? Math.max(1, Math.min(5_000, Math.floor(Number(process.env.EPOCH_OCR_REINDEX_SWEEP_LIMIT))))
  : 1_000;
const OCR_REINDEX_SWEEP_CONCURRENCY = Number.isFinite(Number(process.env.EPOCH_OCR_REINDEX_SWEEP_CONCURRENCY))
  ? Math.max(1, Math.min(8, Math.floor(Number(process.env.EPOCH_OCR_REINDEX_SWEEP_CONCURRENCY))))
  : 2;

async function runHighQualityOcrReindexSweep(state: HubState, source: string) {
  if (state.ocrReindexSweepInFlight) return;
  const openAIKey = resolveOpenAIApiKeyFromConfig(state.config);
  if (!openAIKey) return;

  state.ocrReindexSweepInFlight = true;
  try {
    const candidates = await listOcrReindexCandidates(state.pool, { limit: OCR_REINDEX_SWEEP_LIMIT });
    if (candidates.length === 0) return;

    let cursor = 0;
    const worker = async () => {
      while (true) {
        const candidate = candidates[cursor];
        cursor += 1;
        if (!candidate) return;
        await enqueueUploadIndexing(state, {
          projectId: candidate.projectId,
          artifactPath: candidate.artifactPath,
          uploadId: candidate.uploadId,
          storedPath: candidate.storedPath,
          contentType: candidate.contentType,
        }).catch((err) => {
          const message = err instanceof Error ? err.message : String(err ?? "unknown");
          console.warn(`[ocr-reindex:${source}] failed for ${candidate.projectId}/${candidate.artifactPath}: ${message}`);
        });
      }
    };

    const workerCount = Math.min(OCR_REINDEX_SWEEP_CONCURRENCY, candidates.length);
    await Promise.all(Array.from({ length: workerCount }, () => worker()));
  } finally {
    state.ocrReindexSweepInFlight = false;
  }
}

async function deleteArtifact(state: HubState, projectId: string, artifactPath: string) {
  const artifact = await getArtifactByPath(state, projectId, artifactPath);
  if (!artifact) return null;

  // Look up upload record to delete stored file from disk
  const indexRows = await state.pool.query<any>(
    `SELECT upload_id FROM project_file_index WHERE project_id=$1 AND artifact_path=$2`,
    [projectId, artifactPath]
  );
  const uploadId = indexRows.rows.length > 0 ? String(indexRows.rows[0].upload_id ?? "") : null;

  if (uploadId) {
    const uploadRows = await state.pool.query<any>(
      `SELECT stored_path FROM uploads WHERE id=$1`,
      [uploadId]
    );
    if (uploadRows.rows.length > 0) {
      const storedPath = String(uploadRows.rows[0].stored_path ?? "");
      if (storedPath) {
        await rm(storedPath, { force: true }).catch(() => {});
      }
    }
  }

  // Delete DB records (chunks, index, uploads, artifact)
  await state.pool.query(`DELETE FROM project_file_chunk WHERE project_id=$1 AND artifact_path=$2`, [projectId, artifactPath]);
  await state.pool.query(`DELETE FROM project_file_index WHERE project_id=$1 AND artifact_path=$2`, [projectId, artifactPath]);
  if (uploadId) {
    await state.pool.query(`DELETE FROM uploads WHERE id=$1`, [uploadId]);
  }
  await state.pool.query(`DELETE FROM artifacts WHERE project_id=$1 AND path=$2`, [projectId, artifactPath]);

  // Clean up synced files on HPC workspace
  if (state.node) {
    const textPath = artifactPath.replace(/\.[^.]+$/, ".txt");
    // Remove original file
    void callNode(state, "runtime.fs.write", {
      projectId,
      path: `context/${artifactPath}`,
      data: "",
      encoding: "utf8",
      permissionLevel: "full",
    }).catch(() => {});
    // Remove extracted text
    void callNode(state, "runtime.fs.write", {
      projectId,
      path: `context/${textPath}`,
      data: "",
      encoding: "utf8",
      permissionLevel: "full",
    }).catch(() => {});
    void callNode(state, "runtime.fs.write", {
      projectId,
      path: `context/${textPath}.summary`,
      data: "",
      encoding: "utf8",
      permissionLevel: "full",
    }).catch(() => {});
  }

  return artifact;
}

async function upsertArtifact(
  state: HubState,
  artifact: { projectId: string; path: string; origin: "user_upload" | "generated" | "link_upload"; modifiedAt: string; sizeBytes?: number; sourceUrl?: string }
) {
  const kind = inferArtifactKind(artifact.path);
  const id = uuidv4();
  await state.pool.query(
    `INSERT INTO artifacts (id, project_id, path, kind, origin, modified_at, size_bytes, source_url)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
     ON CONFLICT (project_id, path) DO UPDATE SET
       kind=EXCLUDED.kind,
       origin=EXCLUDED.origin,
       modified_at=EXCLUDED.modified_at,
       size_bytes=COALESCE(EXCLUDED.size_bytes, artifacts.size_bytes),
       source_url=COALESCE(EXCLUDED.source_url, artifacts.source_url)`,
    [id, artifact.projectId, artifact.path, kind, artifact.origin, artifact.modifiedAt, artifact.sizeBytes ?? null, artifact.sourceUrl ?? null]
  );
}

function inferArtifactKind(p: string) {
  const ext = path.posix.extname(p).toLowerCase().replace(".", "");
  switch (ext) {
    case "ipynb":
      return "notebook";
    case "py":
      return "python";
    case "png":
    case "jpg":
    case "jpeg":
      return "image";
    case "txt":
    case "md":
      return "text";
    case "json":
      return "json";
    case "log":
      return "log";
    default:
      return "unknown";
  }
}

async function persistAssistantMessage(state: HubState, msg: {
  projectId: string;
  sessionId: string;
  id: string;
  text: string;
  proposedPlan: any | null;
  artifactRefs: any[];
  usage?: { input: number; output: number; totalTokens: number } | null;
  modelId?: string;
  contextWindowTokens?: number;
  runId?: string;
}) {
  const now = new Date().toISOString();
  const message = {
    id: msg.id,
    sessionID: msg.sessionId,
    role: "assistant",
    text: msg.text,
    createdAt: now,
    artifactRefs: sanitizeArtifactRefsForTransport(msg.artifactRefs ?? []),
    proposedPlan: msg.proposedPlan,
    runID: msg.runId ?? null,
    parentID: null,
  };

  await appendTranscriptLine(state, msg.projectId, msg.sessionId, {
    id: msg.id,
    ts: now,
    role: "assistant",
    content: msg.text,
    artifactRefs: msg.artifactRefs,
    proposedPlan: msg.proposedPlan,
    runId: msg.runId ?? null,
  });

  await state.pool.query(
    `INSERT INTO messages (id, project_id, session_id, ts, role, content, artifact_refs, proposed_plan, run_id, parent_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [
      msg.id,
      msg.projectId,
      msg.sessionId,
      now,
      "assistant",
      msg.text,
      JSON.stringify(msg.artifactRefs ?? []),
      msg.proposedPlan ? JSON.stringify(msg.proposedPlan) : null,
      msg.runId ?? null,
      null,
    ]
  );

  await state.pool.query(
    `UPDATE sessions SET
       updated_at=$1,
       last_message_preview=$2,
       last_message_at=$1,
       context_model_id=COALESCE($3, context_model_id),
       context_window_tokens=COALESCE($4, context_window_tokens),
       context_used_input_tokens=COALESCE($5, context_used_input_tokens),
       context_used_tokens=COALESCE($6, context_used_tokens),
       context_updated_at=COALESCE($7, context_updated_at)
     WHERE id=$8 AND project_id=$9`,
    [
      now,
      preview(msg.text),
      msg.modelId ?? null,
      msg.contextWindowTokens ?? null,
      msg.usage ? Math.max(0, Math.floor(msg.usage.input)) : null,
      msg.usage ? Math.max(0, Math.floor(msg.usage.totalTokens)) : null,
      msg.usage ? now : null,
      msg.sessionId,
      msg.projectId,
    ]
  );

  broadcastEvent(state, "chat.message.created", { projectId: msg.projectId, sessionId: msg.sessionId, message });

  if (msg.usage && typeof msg.contextWindowTokens === "number" && Number.isFinite(msg.contextWindowTokens)) {
    const usedInputTokens = Math.max(0, Math.floor(msg.usage.input));
    const usedTokens = Math.max(0, Math.floor(msg.usage.totalTokens));
    const total = Math.max(1, Math.floor(msg.contextWindowTokens));
    const remainingTokens = Math.max(0, total - usedInputTokens);
    broadcastEvent(state, "sessions.context.updated", {
      projectId: msg.projectId,
      sessionId: msg.sessionId,
      modelId: typeof msg.modelId === "string" ? msg.modelId : null,
      contextWindowTokens: total,
      usedInputTokens,
      usedTokens,
      remainingTokens,
      updatedAt: now,
    });
  }
}

async function persistToolMessage(state: HubState, projectId: string, sessionId: string, text: string, runId?: string) {
  const now = new Date().toISOString();
  const id = uuidv4();
  const message = {
    id,
    sessionID: sessionId,
    role: "tool",
    text,
    createdAt: now,
    artifactRefs: [],
    proposedPlan: null,
    runID: runId ?? null,
    parentID: null,
  };

  await appendTranscriptLine(state, projectId, sessionId, {
    id,
    ts: now,
    role: "tool",
    content: text,
    artifactRefs: [],
    proposedPlan: null,
    runId: runId ?? null,
  });

  await state.pool.query(
    `INSERT INTO messages (id, project_id, session_id, ts, role, content, artifact_refs, proposed_plan, run_id, parent_id)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [id, projectId, sessionId, now, "tool", text, JSON.stringify([]), null, runId ?? null, null]
  );

  broadcastEvent(state, "chat.message.created", { projectId, sessionId, message });
}

async function ensureBootstrapDefaults(state: HubState, projectId: string) {
  const files: Array<[string, string]> = [
    [
      "AGENTS.md",
      `# AGENTS.md\n\n- This workspace is managed by Epoch Hub.\n- Uploaded project files are available in the \`context/uploads/\` directory.\n  - Original files are synced as-is (e.g. \`context/uploads/paper.pdf\`).\n  - Each file also has a \`.txt\` version with full extracted text (e.g. \`context/uploads/paper.txt\`).\n  - Each file also has a \`.txt.summary\` sidecar with a brief summary.\n  - To read an uploaded file, use: cat context/uploads/<filename>.txt\n- Session memory is the canonical chat transcript JSONL.\n- Bootstrap memory files are injected into the agent context on every run.\n`,
    ],
    [
      "USERS.md",
      `# USERS.md\n\n- Preferences: iPhone-first UI, streaming chat, approvals.\n- Default: ask for confirmation before any side effects.\n`,
    ],
    ["SOUL.md", `# SOUL.md\n\n- Identity: Epoch research assistant.\n- Tone: concise, direct, friendly.\n`],
    ["TOOLS.md", `# TOOLS.md\n\n- Approvals gate any side effects.\n`],
  ];

  for (const [name, content] of files) {
    const filePath = path.join(projectBootstrapDir(state, projectId), name);
    try {
      await stat(filePath);
    } catch {
      if (name === "USERS.md") {
        const legacyPath = path.join(projectBootstrapDir(state, projectId), "USER.md");
        if (existsSync(legacyPath)) {
          const legacy = await readFile(legacyPath, "utf8").catch(() => null);
          if (legacy != null) {
            await writeFile(filePath, legacy, "utf8");
            continue;
          }
        }
      }
      await writeFile(filePath, content, "utf8");
    }
  }
}

async function getBootstrapFiles(state: HubState, projectId: string) {
  try {
    await stat(projectDir(state, projectId));
  } catch {
    return [];
  }
  const dir = projectBootstrapDir(state, projectId);
  const names = ["AGENTS.md", "USERS.md", "SOUL.md", "TOOLS.md"];
  const out: Array<{ name: string; content: string }> = [];
  for (const name of names) {
    const filePath = name === "USERS.md" ? resolveUsersBootstrapPath(dir) : path.join(dir, name);
    try {
      const content = await readFile(filePath, "utf8");
      out.push({ name, content });
    } catch {
      out.push({ name, content: "" });
    }
  }
  return out;
}

async function updateBootstrapFile(state: HubState, projectId: string, name: string, content: string) {
  const normalized = normalizeBootstrapFilename(name);
  if (!normalized) return false;
  try {
    await stat(projectDir(state, projectId));
  } catch {
    return false;
  }
  await mkdir(projectBootstrapDir(state, projectId), { recursive: true });
  const dir = projectBootstrapDir(state, projectId);
  const target = normalized === "USERS.md" ? resolveUsersBootstrapPath(dir, { preferLegacyIfPresent: true }) : path.join(dir, normalized);
  await writeFile(target, content, "utf8");
  if (normalized === "AGENTS.md") {
    await syncAgentsHubToHpc(state, projectId, content, "workspace.bootstrap.update").catch((err) => {
      void insertProjectAgentsSyncEvent(state, {
        projectId,
        source: "workspace.bootstrap.update",
        action: "push_to_hpc",
        hash: sha256(content),
        error: String(err instanceof Error ? err.message : err ?? "unknown"),
      });
    });
  }
  return true;
}

function normalizeBootstrapFilename(name: string): "AGENTS.md" | "USERS.md" | "SOUL.md" | "TOOLS.md" | null {
  const n = String(name ?? "").trim().toUpperCase();
  switch (n) {
    case "AGENTS.MD":
      return "AGENTS.md";
    case "USERS.MD":
    case "USER.MD":
      return "USERS.md";
    case "SOUL.MD":
      return "SOUL.md";
    case "TOOLS.MD":
      return "TOOLS.md";
    default:
      return null;
  }
}

function resolveUsersBootstrapPath(dir: string, opts?: { preferLegacyIfPresent?: boolean }) {
  const usersPath = path.join(dir, "USERS.md");
  if (existsSync(usersPath)) return usersPath;
  const legacyPath = path.join(dir, "USER.md");
  if (existsSync(legacyPath)) return legacyPath;
  if (opts?.preferLegacyIfPresent && existsSync(legacyPath)) return legacyPath;
  return usersPath;
}

async function appendTranscriptLine(state: HubState, projectId: string, sessionId: string, obj: any) {
  await mkdir(projectSessionsDir(state, projectId), { recursive: true });
  await appendFile(sessionTranscriptPath(state, projectId, sessionId), JSON.stringify(obj) + "\n", "utf8");
}

async function loadTranscriptMessagesFromJsonl(
  state: HubState,
  projectId: string,
  sessionId: string,
  opts: { limit: number }
): Promise<Array<{ ts: string; role: string; content: string }>> {
  const transcriptPath = sessionTranscriptPath(state, projectId, sessionId);
  const raw = await readFile(transcriptPath, "utf8").catch(() => "");
  const lines = raw.split(/\r?\n/);
  const out: Array<{ ts: string; role: string; content: string }> = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const obj: any = JSON.parse(line);
      if (!obj || typeof obj.role !== "string" || typeof obj.content !== "string") continue;
      const artifactRefs = Array.isArray(obj.artifactRefs) ? obj.artifactRefs : [];
      const content = obj.role === "user"
        ? appendAttachmentSummaryToText(String(obj.content), artifactRefs)
        : String(obj.content);
      out.push({ ts: toIso(obj.ts), role: obj.role, content });
    } catch {
      // ignore parse errors
    }
  }
  return out.slice(Math.max(0, out.length - Math.max(1, Math.floor(opts.limit))));
}

async function writeTranscriptEntriesToJsonl(state: HubState, projectId: string, sessionId: string, entries: any[]) {
  await mkdir(projectSessionsDir(state, projectId), { recursive: true });
  const body = entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
  await writeFile(sessionTranscriptPath(state, projectId, sessionId), body, "utf8");
}

async function writeGeneratedArtifact(state: HubState, projectId: string, relativePath: string, content: string) {
  const clean = normalizeRelativePath(relativePath);
  if (!clean) return;
  const outPath = path.join(projectGeneratedDir(state, projectId), clean);
  await mkdir(path.dirname(outPath), { recursive: true });
  await writeFile(outPath, content, "utf8");
}

async function repairMessagesFromJsonl(state: HubState) {
  const root = path.join(state.stateDir, "projects");
  const projects = await readdir(root).catch(() => []);
  for (const projectId of projects) {
    const sessionsPath = path.join(root, projectId, "sessions");
    const files = await readdir(sessionsPath).catch(() => []);
    for (const file of files) {
      if (!file.endsWith(".jsonl")) continue;
      const sessionId = file.slice(0, -".jsonl".length);
      const transcriptPath = path.join(sessionsPath, file);
      const raw = await readFile(transcriptPath, "utf8").catch(() => "");
      const lines = raw.split("\n").filter((l) => l.trim());
      const entries: any[] = [];
      for (const line of lines) {
        try {
          const entry = JSON.parse(line);
          if (!entry || !entry.id || !entry.ts || !entry.role) continue;
          entries.push(entry);
        } catch {
          continue;
        }
      }

      const countRes = await state.pool.query<{ count: string }>(
        "SELECT COUNT(1) as count FROM messages WHERE project_id=$1 AND session_id=$2",
        [projectId, sessionId]
      );
      const dbCount = Number(countRes.rows[0]?.count ?? "0");
      const transcriptCount = entries.length;
      // The JSONL transcript is treated as the agent "memory" and may be compacted,
      // so it can legitimately have fewer entries than the UI message log in SQLite.
      // Only repair the DB when it is missing transcript entries.
      if (dbCount >= transcriptCount) continue;

      for (const entry of entries) {
        const role = String(entry.role);
        const content = String(entry.content ?? "");
        const artifactRefs = entry.artifactRefs ?? [];
        const proposedPlan = entry.proposedPlan ?? null;
        await state.pool.query(
          `INSERT INTO messages (id, project_id, session_id, ts, role, content, artifact_refs, proposed_plan)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
           ON CONFLICT (id) DO NOTHING`,
          [entry.id, projectId, sessionId, entry.ts, role, content, JSON.stringify(artifactRefs), proposedPlan ? JSON.stringify(proposedPlan) : null]
        );
      }
    }
  }
}

async function handleNodeEvent(state: HubState, event: string, payload: any) {
  const normalizedPayload =
    payload && typeof payload === "object" && !Array.isArray(payload) ? (payload as Record<string, unknown>) : {};
  fanoutNodeEvent(state, event, normalizedPayload);

  switch (event) {
    case "node.heartbeat": {
      state.resources = mergeResourceSnapshotFromHeartbeat(state.resources, payload);
      const connectedNode = state.node?.ctx?.role === "node" ? state.node.ctx : null;
      if (connectedNode) {
        await upsertNodeConnectionSnapshot(state.pool, connectedNode).catch(() => {
          // best effort
        });
      }
      void drainWorkspaceProvisioningQueue(state).catch(() => {
        // best effort
      });
      return;
    }
    case "runs.log.delta": {
      broadcastEvent(state, "runs.log.delta", payload);
      return;
    }
    case "artifacts.updated": {
      const projectId = String(payload.projectId ?? "");
      const artifacts = Array.isArray(payload.artifacts) ? payload.artifacts : [];
      for (const a of artifacts) {
        const p = String(a.path ?? "");
        if (!projectId || !p) continue;
        await upsertArtifact(state, {
          projectId,
          path: p,
          origin: "generated",
          modifiedAt: typeof a.modifiedAt === "string" ? a.modifiedAt : new Date().toISOString(),
          sizeBytes: typeof a.sizeBytes === "number" ? a.sizeBytes : undefined,
        });
        broadcastEvent(state, "artifacts.updated", {
          projectId,
          artifact: await getArtifactByPath(state, projectId, p),
          change: "updated",
        });
      }
      return;
    }
    case "slurm.job.updated": {
      const projectId = String(payload.projectId ?? "");
      const runId = String(payload.runId ?? "");
      const stateStr = String(payload.state ?? "");
      if (!projectId || !runId) return;

      const mapped = mapSlurmState(stateStr);
      await updateRun(state, projectId, runId, (run) => {
        run.status = mapped.status;
        run.log_snippet = mapped.logSnippet;
        if (mapped.completed) {
          run.completed_at = new Date().toISOString();
          if (typeof run.total_steps === "number" && run.current_step < run.total_steps) {
            run.current_step = run.total_steps;
          }
        } else if (typeof run.current_step === "number" && run.current_step < 1) {
          run.current_step = 1;
        }
        return run;
      });
      broadcastEvent(state, "runs.updated", {
        projectId,
        run: await getRun(state, projectId, runId),
        change: "updated",
      });
      return;
    }
    case "runtime.fs.changed": {
      const projectId = normalizeId(payload.projectId);
      const changedPath = normalizeRelativePath(String(payload.path ?? ""));
      if (!projectId || !changedPath) return;
      if (!isAgentsPath(changedPath)) return;
      await reconcileAgentsFromHpc(state, projectId, "runtime.fs.changed").catch((err) => {
        void insertProjectAgentsSyncEvent(state, {
          projectId,
          source: "runtime.fs.changed",
          action: "pull_from_hpc",
          hash: "",
          error: String(err instanceof Error ? err.message : err ?? "unknown"),
        });
      });
      return;
    }
    default:
      return;
  }
}

function fanoutNodeEvent(state: HubState, event: string, payload: Record<string, unknown>) {
  if (state.nodeEventSubscribers.size === 0) return;
  for (const subscriber of state.nodeEventSubscribers) {
    try {
      subscriber(event, payload);
    } catch {
      // ignore subscriber errors
    }
  }
}

function mapSlurmState(stateStr: string) {
  const s = stateStr.toUpperCase();
  if (s.includes("RUNNING")) return { status: "running", logSnippet: "Running", completed: false };
  if (s.includes("COMPLETED")) return { status: "succeeded", logSnippet: "Completed", completed: true };
  if (s.includes("CANCELLED")) return { status: "canceled", logSnippet: "Canceled", completed: true };
  if (s.includes("FAILED")) return { status: "failed", logSnippet: "Failed", completed: true };
  return { status: "queued", logSnippet: s || "Queued", completed: false };
}

function normalizeCodexEngine(raw: unknown): "codex-app-server" | null {
  if (typeof raw !== "string") return null;
  const value = raw.trim().toLowerCase();
  if (value === "pi" || value === "pi-adapter") return "codex-app-server";
  if (value === "codex" || value === "codex-app-server") return "codex-app-server";
  return null;
}

function safeJsonObject(raw: unknown): Record<string, unknown> | null {
  if (!raw) return null;
  if (typeof raw === "object" && !Array.isArray(raw)) {
    return raw as Record<string, unknown>;
  }
  if (typeof raw !== "string") return null;
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    return parsed as Record<string, unknown>;
  } catch {
    return null;
  }
}

function safeJsonString(raw: unknown): string | null {
  if (raw == null) return null;
  if (typeof raw === "string") {
    const trimmed = raw.trim();
    if (!trimmed) return null;
    try {
      const parsed = JSON.parse(trimmed);
      return JSON.stringify(parsed);
    } catch {
      return JSON.stringify(raw);
    }
  }
  if (typeof raw === "object") {
    try {
      return JSON.stringify(raw);
    } catch {
      return null;
    }
  }
  return null;
}

function resolveProjectWorkspacePath(state: HubState, projectId: string, requestedWorkspacePath?: string): string {
  const requested = normalizeOptionalString(requestedWorkspacePath);
  if (requested) {
    return path.resolve(requested);
  }
  return path.join(resolveConfiguredWorkspaceRoot({ stateDir: state.stateDir, config: state.config, env: process.env }), "projects", projectId);
}

async function queueWorkspaceProvisioning(
  state: HubState,
  args: { projectId: string; workspacePath: string; requestedBy: string }
) {
  const now = new Date().toISOString();
  await state.pool.query(
    `INSERT INTO workspace_provisioning_queue (
       project_id, workspace_path, status, attempts, last_error, requested_by, created_at, updated_at
     ) VALUES ($1,$2,'queued',0,NULL,$3,$4,$4)`,
    [args.projectId, args.workspacePath, args.requestedBy, now]
  );
  await state.pool.query(
    `UPDATE projects
     SET hpc_workspace_path=$1, hpc_workspace_state='queued', updated_at=$2
     WHERE id=$3`,
    [args.workspacePath, now, args.projectId]
  );
}

async function drainWorkspaceProvisioningQueue(state: HubState) {
  if (!state.node) return;

  const rows = await state.pool.query<any>(
    `SELECT id, project_id, workspace_path, attempts
     FROM workspace_provisioning_queue
     WHERE status IN ('queued','retry','in_progress')
     ORDER BY id ASC
     LIMIT 50`
  );

  for (const row of rows.rows) {
    const queueId = Number((row as any).id ?? 0);
    const projectId = String((row as any).project_id ?? "");
    const workspacePath = String((row as any).workspace_path ?? "");
    const attempts = Number((row as any).attempts ?? 0);
    if (!queueId || !projectId) continue;

    const now = new Date().toISOString();
    await state.pool.query(
      `UPDATE workspace_provisioning_queue
       SET status='in_progress', attempts=$1, updated_at=$2
       WHERE id=$3`,
      [attempts + 1, now, queueId]
    );

    try {
      const response = await callNode(state, "workspace.project.ensure", {
        projectId,
      });
      const resolvedWorkspacePath = normalizeOptionalString((response as any)?.workspacePath) ?? workspacePath;

      await state.pool.query(
        `UPDATE workspace_provisioning_queue
         SET status='completed', last_error=NULL, updated_at=$1
         WHERE id=$2`,
        [new Date().toISOString(), queueId]
      );
      await state.pool.query(
        `UPDATE projects
         SET hpc_workspace_path=$1, hpc_workspace_state='ready', updated_at=$2
         WHERE id=$3`,
        [resolvedWorkspacePath, new Date().toISOString(), projectId]
      );
      const agentsPath = path.join(projectBootstrapDir(state, projectId), "AGENTS.md");
      const agentsContent = await readFile(agentsPath, "utf8").catch(() => "");
      if (agentsContent.trim()) {
        await syncAgentsHubToHpc(state, projectId, agentsContent, "workspace.project.ensure").catch((err) => {
          void insertProjectAgentsSyncEvent(state, {
            projectId,
            source: "workspace.project.ensure",
            action: "push_to_hpc",
            hash: sha256(agentsContent),
            error: String(err instanceof Error ? err.message : err ?? "unknown"),
          });
        });
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err ?? "workspace provisioning failed");
      await state.pool.query(
        `UPDATE workspace_provisioning_queue
         SET status='queued', last_error=$1, updated_at=$2
         WHERE id=$3`,
        [message.slice(0, 800), new Date().toISOString(), queueId]
      );
      await state.pool.query(
        `UPDATE projects
         SET hpc_workspace_state='queued', updated_at=$1
         WHERE id=$2`,
        [new Date().toISOString(), projectId]
      );
    }
  }
}

type WorkspaceListEntry = {
  path: string;
  type: "file" | "dir";
  sizeBytes?: number;
  modifiedAt?: string;
};

function clampWorkspaceListLimit(raw: unknown): number {
  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return 3_000;
  return Math.max(1, Math.min(20_000, Math.floor(parsed)));
}

function normalizeWorkspaceEntries(raw: unknown): WorkspaceListEntry[] {
  if (!Array.isArray(raw)) return [];
  const out: WorkspaceListEntry[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
    const obj = entry as Record<string, unknown>;
    const pathValue = normalizeRelativePath(String(obj.path ?? ""));
    const typeRaw = String(obj.type ?? "").trim().toLowerCase();
    if (!pathValue) continue;
    if (typeRaw !== "file" && typeRaw !== "dir") continue;
    const normalized: WorkspaceListEntry = {
      path: pathValue,
      type: typeRaw,
    };
    if (typeof obj.sizeBytes === "number" && Number.isFinite(obj.sizeBytes)) {
      normalized.sizeBytes = Math.max(0, Math.floor(obj.sizeBytes));
    }
    if (typeof obj.modifiedAt === "string" && obj.modifiedAt.trim()) {
      normalized.modifiedAt = obj.modifiedAt;
    }
    out.push(normalized);
  }
  out.sort((a, b) => a.path.localeCompare(b.path));
  return out;
}

function isUploadsWorkspacePath(pathValue: string): boolean {
  const normalized = normalizeRelativePath(pathValue);
  if (!normalized) return false;
  return normalized === "uploads" || normalized.startsWith("uploads/");
}

function isAgentsPath(pathValue: string): boolean {
  const normalized = normalizeRelativePath(pathValue);
  return normalized === "AGENTS.md";
}

async function assertWorkspaceRuntimeReady(state: HubState, projectId: string) {
  const commands = new Set(state.localRuntime.listNodeCommands());
  const required = ["runtime.fs.list", "runtime.fs.read", "runtime.fs.stat"];
  const missing = required.filter((method) => !commands.has(method));
  if (missing.length > 0) {
    throw new Error(`CAPABILITY_MISSING: local runtime missing methods (${missing.join(", ")})`);
  }
  const row = await state.pool.query<{ hpc_workspace_path: string | null }>(
    "SELECT hpc_workspace_path FROM projects WHERE id=$1 LIMIT 1",
    [projectId]
  );
  if (row.rows.length === 0) {
    throw new Error("NOT_FOUND: project not found");
  }
  const persistedPath = normalizeOptionalString(row.rows[0]?.hpc_workspace_path);
  if (!persistedPath) {
    throw new Error("BAD_REQUEST: project workspace is not provisioned");
  }
}

function classifyGatewayError(err: unknown): { code: "NODE_OFFLINE" | "BAD_REQUEST" | "NOT_FOUND" | "INTERNAL"; message: string } {
  const message = String(err instanceof Error ? err.message : err ?? "internal error");
  if (message === "NODE_OFFLINE" || message.startsWith("NODE_OFFLINE:")) {
    return { code: "NODE_OFFLINE", message: message === "NODE_OFFLINE" ? "Epoch runtime is unavailable" : message };
  }
  if (message.startsWith("NOT_FOUND:")) return { code: "NOT_FOUND", message: message.slice("NOT_FOUND:".length).trim() || message };
  if (message.startsWith("CAPABILITY_MISSING:")) return { code: "BAD_REQUEST", message };
  if (message.startsWith("BAD_REQUEST:")) return { code: "BAD_REQUEST", message: message.slice("BAD_REQUEST:".length).trim() || message };
  return { code: "INTERNAL", message };
}

async function updateOpenAISettings(
  state: HubState,
  args: {
    hasApiKey: boolean;
    apiKey?: string | null;
    clear: boolean;
    ocrModel?: string | null;
    hasOcrModel: boolean;
    source: string;
  }
) {
  const providerApiKeys = { ...(state.config.providerApiKeys ?? {}) };
  const providerApiKeyMetadata = { ...(state.config.providerApiKeyMetadata ?? {}) };
  if (args.clear) {
    delete providerApiKeys.openai;
  } else if (args.hasApiKey) {
    const normalizedKey = normalizeOptionalString(args.apiKey);
    if (normalizedKey) {
      providerApiKeys.openai = normalizedKey;
    } else {
      delete providerApiKeys.openai;
    }
  }
  providerApiKeyMetadata.openai = {
    updatedAt: new Date().toISOString(),
    source: args.source,
  };

  if (Object.keys(providerApiKeys).length === 0) {
    delete state.config.providerApiKeys;
  } else {
    state.config.providerApiKeys = providerApiKeys;
  }

  if (args.hasOcrModel) {
    const nextOpenAISettings = { ...(state.config.openaiSettings ?? {}) };
    const normalizedOcrModel = normalizeOptionalString(args.ocrModel);
    if (normalizedOcrModel) {
      nextOpenAISettings.ocrModel = normalizedOcrModel;
    } else {
      delete nextOpenAISettings.ocrModel;
    }
    if (Object.keys(nextOpenAISettings).length === 0) {
      delete state.config.openaiSettings;
    } else {
      state.config.openaiSettings = nextOpenAISettings;
    }
  }

  state.config.providerApiKeyMetadata = providerApiKeyMetadata;
  await saveHubConfig({ stateDir: state.stateDir, config: state.config });
}

async function reconcileAgentsFromHpc(state: HubState, projectId: string, source: string) {
  if (!state.node) return;
  try {
    await assertWorkspaceRuntimeReady(state, projectId);
  } catch {
    return;
  }
  const hubAgentsPath = path.join(projectBootstrapDir(state, projectId), "AGENTS.md");
  await ensureBootstrapDefaults(state, projectId).catch(() => {
    // best effort bootstrap defaults
  });
  const localContent = await readFile(hubAgentsPath, "utf8").catch(() => "");
  const localHash = sha256(localContent);
  const localStat = await stat(hubAgentsPath).catch(() => null);
  const localMtime = localStat?.mtime?.toISOString() ?? null;

  const remoteStatRes = await callNode(state, "runtime.fs.stat", { projectId, path: "AGENTS.md" }).catch(() => null);
  if (!remoteStatRes || !(remoteStatRes as any).exists) {
    if (!localContent.trim()) return;
    await syncAgentsHubToHpc(state, projectId, localContent, source).catch((err) => {
      void insertProjectAgentsSyncEvent(state, {
        projectId,
        source,
        action: "push_to_hpc",
        hash: sha256(localContent),
        error: String(err instanceof Error ? err.message : err ?? "unknown"),
      }).catch(() => {
        // best effort
      });
    });
    return;
  }
  const remoteMtime = normalizeOptionalString((remoteStatRes as any).modifiedAt);

  const remoteReadRes = await callNode(state, "runtime.fs.read", {
    projectId,
    path: "AGENTS.md",
    offset: 0,
    length: 2 * 1024 * 1024,
    encoding: "utf8",
  }).catch(() => null);
  if (!remoteReadRes) return;
  const remoteContent = String((remoteReadRes as any).data ?? "");
  const remoteHash = sha256(remoteContent);
  if (remoteHash === localHash) return;
  if (shouldSkipAgentsSync(state, projectId, remoteHash, source)) return;

  const localTs = localMtime ? Date.parse(localMtime) : 0;
  const remoteTs = remoteMtime ? Date.parse(remoteMtime) : 0;
  if (Number.isFinite(localTs) && Number.isFinite(remoteTs) && localTs >= remoteTs) {
    // Hub wins, push current content to HPC.
    await syncAgentsHubToHpc(state, projectId, localContent, source);
    return;
  }

  await mkdir(projectBootstrapDir(state, projectId), { recursive: true });
  await writeFile(hubAgentsPath, remoteContent, "utf8");
  markAgentsSyncMemo(state, projectId, remoteHash, source);
  await insertProjectAgentsSyncEvent(state, {
    projectId,
    source,
    action: "pull_from_hpc",
    hash: remoteHash,
    error: null,
  }).catch(() => {
    // best effort
  });
}

async function syncAgentsHubToHpc(state: HubState, projectId: string, content: string, source: string) {
  if (!state.node) return;
  const contentHash = sha256(content);
  if (shouldSkipAgentsSync(state, projectId, contentHash, source)) {
    return;
  }
  await callNode(state, "runtime.fs.write", {
    projectId,
    path: "AGENTS.md",
    data: content,
    encoding: "utf8",
    permissionLevel: "full",
  });
  markAgentsSyncMemo(state, projectId, contentHash, source);
  await insertProjectAgentsSyncEvent(state, {
    projectId,
    source,
    action: "push_to_hpc",
    hash: contentHash,
    error: null,
  }).catch(() => {
    // best effort
  });
}

async function insertProjectAgentsSyncEvent(
  state: HubState,
  args: { projectId: string; source: string; action: string; hash: string; error: string | null }
) {
  await state.pool.query(
    `INSERT INTO project_agents_sync_events (id, project_id, source, action, hash, ts, error)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [uuidv4(), args.projectId, args.source, args.action, args.hash, new Date().toISOString(), args.error]
  );
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function shouldSkipAgentsSync(state: HubState, projectId: string, hash: string, source: string): boolean {
  const key = projectId;
  const memo = state.agentsSyncMemo.get(key);
  if (!memo) return false;
  const withinTtl = Date.now() - memo.ts < 30_000;
  return withinTtl && memo.hash === hash && memo.source === source;
}

function markAgentsSyncMemo(state: HubState, projectId: string, hash: string, source: string) {
  state.agentsSyncMemo.set(projectId, {
    hash,
    source,
    ts: Date.now(),
  });
}

async function callNode(state: HubState, method: NodeMethod, params: any) {
  if (state.localRuntime) {
    const localParams = await attachWorkspacePathForLocalRuntime(state, params);
    return await state.localRuntime.callNode(method, localParams);
  }
  const node = state.node;
  if (!node) throw new Error("NODE_OFFLINE");
  if (!isNodeMethod(method)) {
    throw new Error(`Unsupported node method: ${method}`);
  }
  const id = uuidv4();
  const frame = { type: "req", id, method, params };
  node.ws.send(JSON.stringify(frame));

  return await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      state.pendingNodeRequests.delete(id);
      reject(new Error("node request timeout"));
    }, 60_000);
    state.pendingNodeRequests.set(id, { resolve, reject, timeout });
  });
}

async function attachWorkspacePathForLocalRuntime(state: HubState, params: Record<string, unknown> | undefined) {
  const normalized = params && typeof params === "object" && !Array.isArray(params)
    ? { ...params }
    : {};
  if (typeof normalized.workspacePath === "string" && normalized.workspacePath.trim()) {
    return normalized;
  }
  const projectId = normalizeId(normalized.projectId);
  if (!projectId) return normalized;
  const rows = await state.pool.query<{ hpc_workspace_path: string | null }>(
    "SELECT hpc_workspace_path FROM projects WHERE id=$1 LIMIT 1",
    [projectId]
  );
  const workspacePath = normalizeOptionalString(rows.rows[0]?.hpc_workspace_path);
  if (workspacePath) {
    normalized.workspacePath = workspacePath;
  }
  return normalized;
}

function preview(text: string) {
  const t = text.replace(/\s+/g, " ").trim();
  return t.length > 140 ? t.slice(0, 140) + "…" : t;
}

async function getApiKeyForProvider(state: HubState, provider: string): Promise<string | undefined> {
  const p = String(provider ?? "").trim();
  if (!p) return undefined;

  if (p === "openai") {
    const openAIKey = resolveOpenAIApiKeyFromConfig(state.config);
    if (openAIKey) return openAIKey;
  }

  const configuredProviderKey = state.config.providerApiKeys?.[p];
  if (typeof configuredProviderKey === "string" && configuredProviderKey.trim().length > 0) {
    return configuredProviderKey.trim();
  }

  const ai = state.config.ai;
  const auth = ai?.auth;

  if (auth?.type === "api_key") {
    if (auth.provider === p && auth.apiKey) return auth.apiKey;
  }

  return getEnvApiKey(p);
}

function parseJson<T>(value: any, fallback: T): T {
  if (value == null) return fallback;
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!trimmed) return fallback;
    try {
      return JSON.parse(trimmed) as T;
    } catch {
      return fallback;
    }
  }
  return value as T;
}

function normalizeIndexStatus(value: unknown): "processing" | "indexed" | "failed" | null {
  const v = String(value ?? "").trim().toLowerCase();
  if (v === "processing" || v === "indexed" || v === "failed") return v;
  return null;
}

export function mergeResourceSnapshotFromHeartbeat(previous: ResourceSnapshot, payload: any): ResourceSnapshot {
  const next: ResourceSnapshot = { ...previous, computeConnected: true };
  if (typeof payload?.storageUsedPercent === "number" && Number.isFinite(payload.storageUsedPercent)) {
    next.storageUsedPercent = payload.storageUsedPercent;
  }
  if (typeof payload?.storageTotalBytes === "number" && Number.isFinite(payload.storageTotalBytes)) {
    next.storageTotalBytes = Math.max(0, Math.floor(payload.storageTotalBytes));
  }
  if (typeof payload?.storageUsedBytes === "number" && Number.isFinite(payload.storageUsedBytes)) {
    next.storageUsedBytes = Math.max(0, Math.floor(payload.storageUsedBytes));
  }
  if (typeof payload?.storageAvailableBytes === "number" && Number.isFinite(payload.storageAvailableBytes)) {
    next.storageAvailableBytes = Math.max(0, Math.floor(payload.storageAvailableBytes));
  }
  if (typeof payload?.cpuPercent === "number" && Number.isFinite(payload.cpuPercent)) {
    next.cpuPercent = payload.cpuPercent;
  }
  if (typeof payload?.ramPercent === "number" && Number.isFinite(payload.ramPercent)) {
    next.ramPercent = payload.ramPercent;
  }
  if (typeof payload?.gpuPercent === "number" && Number.isFinite(payload.gpuPercent)) {
    next.gpuPercent = payload.gpuPercent;
  }
  return next;
}

function normalizeHpcStatus(v: unknown): HpcStatus | undefined {
  if (!v || typeof v !== "object") return undefined;
  const obj = v as any;

  return {
    partition: typeof obj.partition === "string" ? obj.partition : undefined,
    account: typeof obj.account === "string" ? obj.account : undefined,
    qos: typeof obj.qos === "string" ? obj.qos : undefined,
    runningJobs: typeof obj.runningJobs === "number" ? Math.max(0, Math.floor(obj.runningJobs)) : 0,
    pendingJobs: typeof obj.pendingJobs === "number" ? Math.max(0, Math.floor(obj.pendingJobs)) : 0,
    limit: normalizeHpcTres(obj.limit),
    inUse: normalizeHpcTres(obj.inUse),
    available: normalizeHpcTres(obj.available),
    requestable: normalizeHpcTres(obj.requestable),
    supplyPool: normalizeHpcSupplyPool(obj.supplyPool),
    nodes: normalizeHpcNodes(obj.nodes),
    updatedAt: typeof obj.updatedAt === "string" ? obj.updatedAt : new Date().toISOString(),
  };
}

function normalizeHpcTres(v: unknown): HpcTres | undefined {
  if (!v || typeof v !== "object") return undefined;
  const obj = v as any;
  const out: HpcTres = {};
  if (typeof obj.cpu === "number" && Number.isFinite(obj.cpu)) out.cpu = Math.max(0, Math.floor(obj.cpu));
  if (typeof obj.memMB === "number" && Number.isFinite(obj.memMB)) out.memMB = Math.max(0, Math.floor(obj.memMB));
  if (typeof obj.gpus === "number" && Number.isFinite(obj.gpus)) out.gpus = Math.max(0, Math.floor(obj.gpus));
  if (out.cpu == null && out.memMB == null && out.gpus == null) return undefined;
  return out;
}

function normalizeHpcSupplyPool(v: unknown): HpcSupplyPool | undefined {
  if (!v || typeof v !== "object") return undefined;
  const obj = v as any;
  const idleNodes = normalizeOptionalNonNegativeInt(obj.idleNodes);
  const mixedNodes = normalizeOptionalNonNegativeInt(obj.mixedNodes);
  const totalNodes = normalizeOptionalNonNegativeInt(obj.totalNodes);
  if (idleNodes == null || mixedNodes == null || totalNodes == null) return undefined;
  const scope = String(obj.scope ?? "").trim().toUpperCase();
  if (scope !== "IDLE+MIXED") return undefined;
  const out: HpcSupplyPool = {
    idleNodes,
    mixedNodes,
    totalNodes,
    scope: "IDLE+MIXED",
    updatedAt: typeof obj.updatedAt === "string" ? obj.updatedAt : new Date().toISOString(),
  };
  const availableCpu = normalizeOptionalNonNegativeInt(obj.availableCpu);
  const availableMemMB = normalizeOptionalNonNegativeInt(obj.availableMemMB);
  const availableGpus = normalizeOptionalNonNegativeInt(obj.availableGpus);
  if (availableCpu != null) out.availableCpu = availableCpu;
  if (availableMemMB != null) out.availableMemMB = availableMemMB;
  if (availableGpus != null) out.availableGpus = availableGpus;
  return out;
}

function normalizeHpcNodes(v: unknown): HpcNodeUsage[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const rows: HpcNodeUsage[] = [];
  for (const item of v) {
    if (!item || typeof item !== "object") continue;
    const obj = item as any;
    const nodeName = typeof obj.nodeName === "string" ? obj.nodeName.trim() : "";
    const roleRaw = typeof obj.role === "string" ? obj.role.trim().toLowerCase() : "";
    const sourceRaw = typeof obj.source === "string" ? obj.source.trim().toLowerCase() : "";
    if (!nodeName) continue;
    if (roleRaw !== "login" && roleRaw !== "compute") continue;
    if (sourceRaw !== "job" && sourceRaw !== "node_total_fallback") continue;
    if (typeof obj.cpuPercent !== "number" || !Number.isFinite(obj.cpuPercent)) continue;
    if (typeof obj.ramPercent !== "number" || !Number.isFinite(obj.ramPercent)) continue;
    const row: HpcNodeUsage = {
      nodeName,
      role: roleRaw === "login" ? "login" : "compute",
      source: sourceRaw === "job" ? "job" : "node_total_fallback",
      cpuPercent: obj.cpuPercent,
      ramPercent: obj.ramPercent,
      updatedAt: typeof obj.updatedAt === "string" ? obj.updatedAt : new Date().toISOString(),
    };
    if (Array.isArray(obj.jobIds)) {
      const ids = obj.jobIds
        .map((jobId: unknown) => String(jobId ?? "").trim())
        .filter(Boolean);
      if (ids.length > 0) row.jobIds = ids;
    }
    if (typeof obj.gpuPercent === "number" && Number.isFinite(obj.gpuPercent)) {
      row.gpuPercent = obj.gpuPercent;
    }
    rows.push(row);
  }
  return rows;
}

function normalizeOptionalNonNegativeInt(v: unknown): number | undefined {
  if (typeof v !== "number" || !Number.isFinite(v)) return undefined;
  return Math.max(0, Math.floor(v));
}
