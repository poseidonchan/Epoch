import Fastify, { type FastifyInstance } from "fastify";

export type PushRelayDeviceRecord = {
  serverId: string;
  installationId: string;
  apnsToken: string;
  environment: string;
  deviceName: string;
  platform: string;
  updatedAt: number;
};

export type PushRelayLiveEventPayload = {
  serverId: string;
  cursorHint?: number | null;
  changedSessionIds?: string[] | null;
  reason?: string | null;
};

export type SilentPushDispatch = {
  device: PushRelayDeviceRecord;
  payload: {
    serverId: string;
    cursorHint?: number;
    changedSessionIds: string[];
    reason?: string;
  };
};

export interface SilentPushSender {
  sendSilentPush(dispatch: SilentPushDispatch): Promise<void>;
}

export class NoopSilentPushSender implements SilentPushSender {
  async sendSilentPush(_dispatch: SilentPushDispatch): Promise<void> {}
}

type DedupeRecord = {
  fingerprint: string;
  sentAt: number;
};

export class MemoryPushRelayStore {
  private readonly devicesByKey = new Map<string, PushRelayDeviceRecord>();
  private readonly dedupeByKey = new Map<string, DedupeRecord>();

  upsertDevice(device: Omit<PushRelayDeviceRecord, "updatedAt"> & { updatedAt?: number }) {
    const updatedAt = Number(device.updatedAt ?? Date.now());
    this.devicesByKey.set(this.key(device.serverId, device.installationId), {
      ...device,
      updatedAt,
    });
  }

  deleteDevice(serverId: string, installationId: string) {
    this.devicesByKey.delete(this.key(serverId, installationId));
    this.dedupeByKey.delete(this.key(serverId, installationId));
  }

  heartbeatDevice(args: {
    serverId: string;
    installationId: string;
    apnsToken?: string | null;
    environment?: string | null;
    deviceName?: string | null;
    platform?: string | null;
    updatedAt?: number;
  }): PushRelayDeviceRecord | null {
    const existing = this.devicesByKey.get(this.key(args.serverId, args.installationId));
    if (!existing) return null;
    const updated: PushRelayDeviceRecord = {
      serverId: args.serverId,
      installationId: args.installationId,
      apnsToken: normalizeOptionalString(args.apnsToken) ?? existing.apnsToken,
      environment: normalizeOptionalString(args.environment) ?? existing.environment,
      deviceName: normalizeOptionalString(args.deviceName) ?? existing.deviceName,
      platform: normalizeOptionalString(args.platform) ?? existing.platform,
      updatedAt: Number(args.updatedAt ?? Date.now()),
    };
    this.devicesByKey.set(this.key(args.serverId, args.installationId), updated);
    return updated;
  }

  listDevices(serverId: string): PushRelayDeviceRecord[] {
    return Array.from(this.devicesByKey.values())
      .filter((device) => device.serverId === serverId)
      .sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt || lhs.installationId.localeCompare(rhs.installationId));
  }

  shouldDispatchSilentPush(args: {
    serverId: string;
    installationId: string;
    payload: PushRelayLiveEventPayload;
    dedupeWindowMs?: number;
    now?: number;
  }): boolean {
    const now = Number(args.now ?? Date.now());
    const dedupeWindowMs = Math.max(250, Number(args.dedupeWindowMs ?? 5_000));
    const key = this.key(args.serverId, args.installationId);
    const fingerprint = JSON.stringify({
      serverId: args.serverId,
      cursorHint: args.payload.cursorHint ?? null,
      changedSessionIds: normalizedStringArray(args.payload.changedSessionIds),
      reason: normalizeOptionalString(args.payload.reason) ?? null,
    });
    const existing = this.dedupeByKey.get(key);
    if (existing && existing.fingerprint === fingerprint && now - existing.sentAt < dedupeWindowMs) {
      return false;
    }
    this.dedupeByKey.set(key, {
      fingerprint,
      sentAt: now,
    });
    return true;
  }

  private key(serverId: string, installationId: string): string {
    return `${serverId}::${installationId}`;
  }
}

export function createPushRelayService(opts: {
  sharedSecret: string;
  sender?: SilentPushSender;
  store?: MemoryPushRelayStore;
  now?: () => number;
}): FastifyInstance {
  const app = Fastify({ logger: true });
  const sender = opts.sender ?? new NoopSilentPushSender();
  const store = opts.store ?? new MemoryPushRelayStore();
  const now = opts.now ?? (() => Date.now());

  app.addHook("preHandler", async (request, reply) => {
    const provided =
      normalizeOptionalString(request.headers["x-epoch-shared-secret"])
      ?? normalizeBearerToken(request.headers.authorization);
    if (provided !== opts.sharedSecret) {
      reply.code(401).send({ error: "unauthorized" });
    }
  });

  app.post("/v1/devices/register", async (request, reply) => {
    const body = normalizeObject(request.body);
    const serverId = normalizeRequired(body?.serverId, "serverId");
    const installationId = normalizeRequired(body?.installationId, "installationId");
    const apnsToken = normalizeRequired(body?.apnsToken, "apnsToken");
    const environment = normalizeRequired(body?.environment, "environment");
    const deviceName = normalizeRequired(body?.deviceName, "deviceName");
    const platform = normalizeRequired(body?.platform, "platform");

    store.upsertDevice({
      serverId,
      installationId,
      apnsToken,
      environment,
      deviceName,
      platform,
      updatedAt: now(),
    });
    return reply.send({ ok: true });
  });

  app.post("/v1/devices/unregister", async (request, reply) => {
    const body = normalizeObject(request.body);
    const serverId = normalizeRequired(body?.serverId, "serverId");
    const installationId = normalizeRequired(body?.installationId, "installationId");
    store.deleteDevice(serverId, installationId);
    return reply.send({ ok: true });
  });

  app.post("/v1/devices/heartbeat", async (request, reply) => {
    const body = normalizeObject(request.body);
    const serverId = normalizeRequired(body?.serverId, "serverId");
    const installationId = normalizeRequired(body?.installationId, "installationId");
    const updated = store.heartbeatDevice({
      serverId,
      installationId,
      apnsToken: normalizeOptionalString(body?.apnsToken),
      environment: normalizeOptionalString(body?.environment),
      deviceName: normalizeOptionalString(body?.deviceName),
      platform: normalizeOptionalString(body?.platform),
      updatedAt: now(),
    });
    if (!updated) {
      return reply.code(404).send({ error: "not_found" });
    }
    return reply.send({ ok: true });
  });

  app.post("/v1/events/live-session", async (request, reply) => {
    const body = normalizeObject(request.body);
    const serverId = normalizeRequired(body?.serverId, "serverId");
    const payload: PushRelayLiveEventPayload = {
      serverId,
      cursorHint: normalizeOptionalNumber(body?.cursorHint),
      changedSessionIds: normalizedStringArray(body?.changedSessionIds),
      reason: normalizeOptionalString(body?.reason),
    };

    let delivered = 0;
    for (const device of store.listDevices(serverId)) {
      const shouldDispatch = store.shouldDispatchSilentPush({
        serverId,
        installationId: device.installationId,
        payload,
        now: now(),
      });
      if (!shouldDispatch) continue;
      await sender.sendSilentPush({
        device,
        payload: {
          serverId,
          ...(payload.cursorHint != null ? { cursorHint: payload.cursorHint } : {}),
          changedSessionIds: payload.changedSessionIds ?? [],
          ...(payload.reason ? { reason: payload.reason } : {}),
        },
      });
      delivered += 1;
    }

    return reply.send({ ok: true, delivered });
  });

  return app;
}

export async function startPushRelayServer(opts: {
  sharedSecret: string;
  sender?: SilentPushSender;
  store?: MemoryPushRelayStore;
  now?: () => number;
  host?: string;
  port?: number;
}) {
  const app = createPushRelayService(opts);
  await app.listen({
    host: normalizeOptionalString(opts.host) ?? "0.0.0.0",
    port: Math.max(1, Number(opts.port ?? 8788)),
  });
  return app;
}

function normalizeBearerToken(raw: unknown): string | null {
  const value = normalizeOptionalString(raw);
  if (!value) return null;
  const match = value.match(/^Bearer\s+(.+)$/i);
  return match?.[1]?.trim() || null;
}

function normalizeOptionalString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function normalizeRequired(raw: unknown, field: string): string {
  const value = normalizeOptionalString(raw);
  if (!value) {
    throw new Error(`Missing ${field}`);
  }
  return value;
}

function normalizeOptionalNumber(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw)) return raw;
  if (typeof raw === "string" && raw.trim()) {
    const parsed = Number(raw);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function normalizeObject(raw: unknown): Record<string, unknown> | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  return raw as Record<string, unknown>;
}

function normalizedStringArray(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  return Array.from(
    new Set(
      raw
        .map((entry) => normalizeOptionalString(entry))
        .filter((entry): entry is string => entry != null)
    )
  );
}
