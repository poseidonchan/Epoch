import type { SilentPushDispatch, SilentPushSender } from "@epoch/push-relay";

import type { CodexPushDeviceRecord, CodexRepository } from "./codex_rpc/repository.js";
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

export function createPushRelayClient(args: {
  config: HubConfig;
  repository: CodexRepository;
  sender?: SilentPushSender | null;
  now?: () => number;
}): PushRelayClient {
  if (args.config.pushEnabled !== true || !args.sender) {
    return new NoopPushRelayClient();
  }
  return new EmbeddedPushRelayClient(args.repository, args.sender, args.now ?? (() => Date.now()));
}

class NoopPushRelayClient implements PushRelayClient {
  async registerDevice(_args: DeviceRegistrationArgs): Promise<void> {}
  async unregisterDevice(_args: DeviceUnregisterArgs): Promise<void> {}
  async heartbeatDevice(_args: DeviceHeartbeatArgs): Promise<void> {}
  async notifyLiveSession(_args: LiveSessionRelayArgs): Promise<void> {}
}

class EmbeddedPushRelayClient implements PushRelayClient {
  private readonly dedupeByDeviceKey = new Map<string, { fingerprint: string; sentAt: number }>();

  constructor(
    private readonly repository: CodexRepository,
    private readonly sender: SilentPushSender,
    private readonly now: () => number
  ) {}

  async registerDevice(_args: DeviceRegistrationArgs): Promise<void> {}

  async unregisterDevice(args: DeviceUnregisterArgs): Promise<void> {
    this.dedupeByDeviceKey.delete(deviceKey(args.serverId, args.installationId));
  }

  async heartbeatDevice(_args: DeviceHeartbeatArgs): Promise<void> {}

  async notifyLiveSession(args: LiveSessionRelayArgs): Promise<void> {
    const devices = await this.repository.listPushDevices({ serverId: args.serverId });
    const dispatches = devices
      .map((device) => buildDispatch(args, device))
      .filter((dispatch): dispatch is SilentPushDispatch => dispatch != null);

    for (const dispatch of dispatches) {
      if (!this.shouldDispatch(dispatch)) {
        continue;
      }
      try {
        await this.sender.sendSilentPush(dispatch);
      } catch (error) {
        console.warn("failed to send embedded APNs push", {
          error,
          serverId: dispatch.payload.serverId,
          installationId: dispatch.device.installationId,
        });
      }
    }
  }

  private shouldDispatch(dispatch: SilentPushDispatch): boolean {
    const key = deviceKey(dispatch.device.serverId, dispatch.device.installationId);
    const fingerprint = JSON.stringify({
      serverId: dispatch.payload.serverId,
      cursorHint: dispatch.payload.cursorHint ?? null,
      changedSessionIds: dispatch.payload.changedSessionIds,
      reason: dispatch.payload.reason ?? null,
    });
    const now = this.now();
    const previous = this.dedupeByDeviceKey.get(key);
    if (previous && previous.fingerprint === fingerprint && now - previous.sentAt < 5_000) {
      return false;
    }
    this.dedupeByDeviceKey.set(key, {
      fingerprint,
      sentAt: now,
    });
    return true;
  }
}

function buildDispatch(
  args: LiveSessionRelayArgs,
  device: CodexPushDeviceRecord
): SilentPushDispatch | null {
  const serverId = normalizeOptionalString(args.serverId);
  const installationId = normalizeOptionalString(device.installationId);
  const apnsToken = normalizeOptionalString(device.apnsToken);
  const environment = normalizeOptionalString(device.environment);
  if (!serverId || !installationId || !apnsToken || !environment) {
    return null;
  }

  return {
    device: {
      serverId,
      installationId,
      apnsToken,
      environment,
      deviceName: normalizeOptionalString(device.deviceName) ?? "Epoch iPhone",
      platform: normalizeOptionalString(device.platform) ?? "iOS",
      updatedAt: Date.parse(device.updatedAt) || 0,
    },
    payload: {
      serverId,
      ...(args.cursorHint != null ? { cursorHint: args.cursorHint } : {}),
      changedSessionIds: normalizedStringArray(args.changedSessionIds),
      ...(normalizeOptionalString(args.reason) ? { reason: normalizeOptionalString(args.reason)! } : {}),
    },
  };
}

function normalizedStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return Array.from(
    new Set(
      value
        .map((entry) => normalizeOptionalString(entry))
        .filter((entry): entry is string => entry != null)
    )
  );
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function deviceKey(serverId: string, installationId: string): string {
  return `${serverId}::${installationId}`;
}
