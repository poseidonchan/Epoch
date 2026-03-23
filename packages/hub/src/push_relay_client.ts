import type { HubConfig } from "./config.js";

type DeviceRegistrationArgs = {
  serverId: string;
  installationId: string;
  apnsToken: string;
  environment: string;
  deviceName: string;
  platform: string;
};

type DeviceHeartbeatArgs = {
  serverId: string;
  installationId: string;
  apnsToken?: string | null;
  environment?: string | null;
  deviceName?: string | null;
  platform?: string | null;
};

type DeviceUnregisterArgs = {
  serverId: string;
  installationId: string;
};

type LiveSessionRelayArgs = {
  serverId: string;
  cursorHint?: number | null;
  changedSessionIds?: string[] | null;
  reason?: string | null;
};

export interface PushRelayClient {
  registerDevice(args: DeviceRegistrationArgs): Promise<void>;
  unregisterDevice(args: DeviceUnregisterArgs): Promise<void>;
  heartbeatDevice(args: DeviceHeartbeatArgs): Promise<void>;
  notifyLiveSession(args: LiveSessionRelayArgs): Promise<void>;
}

export function createPushRelayClient(config: HubConfig): PushRelayClient {
  const baseUrl = normalizeOptionalString(config.pushRelayUrl);
  const sharedSecret = normalizeOptionalString(config.pushRelaySharedSecret);
  if (config.pushEnabled !== true || !baseUrl || !sharedSecret) {
    return new NoopPushRelayClient();
  }
  return new HttpPushRelayClient(baseUrl, sharedSecret);
}

class NoopPushRelayClient implements PushRelayClient {
  async registerDevice(_args: DeviceRegistrationArgs): Promise<void> {}
  async unregisterDevice(_args: DeviceUnregisterArgs): Promise<void> {}
  async heartbeatDevice(_args: DeviceHeartbeatArgs): Promise<void> {}
  async notifyLiveSession(_args: LiveSessionRelayArgs): Promise<void> {}
}

class HttpPushRelayClient implements PushRelayClient {
  constructor(
    private readonly baseUrl: string,
    private readonly sharedSecret: string
  ) {}

  async registerDevice(args: DeviceRegistrationArgs): Promise<void> {
    await this.post("/v1/devices/register", args);
  }

  async unregisterDevice(args: DeviceUnregisterArgs): Promise<void> {
    await this.post("/v1/devices/unregister", args);
  }

  async heartbeatDevice(args: DeviceHeartbeatArgs): Promise<void> {
    await this.post("/v1/devices/heartbeat", args);
  }

  async notifyLiveSession(args: LiveSessionRelayArgs): Promise<void> {
    await this.post("/v1/events/live-session", {
      serverId: args.serverId,
      ...(args.cursorHint != null ? { cursorHint: args.cursorHint } : {}),
      ...(args.changedSessionIds?.length ? { changedSessionIds: args.changedSessionIds } : {}),
      ...(normalizeOptionalString(args.reason) ? { reason: args.reason } : {}),
    });
  }

  private async post(path: string, payload: Record<string, unknown>) {
    const response = await fetch(new URL(path, ensureTrailingSlash(this.baseUrl)), {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${this.sharedSecret}`,
      },
      body: JSON.stringify(payload),
    });
    if (!response.ok) {
      throw new Error(`Push relay request failed (${response.status})`);
    }
  }
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function ensureTrailingSlash(url: string): string {
  return url.endsWith("/") ? url : `${url}/`;
}
