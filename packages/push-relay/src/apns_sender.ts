import http2 from "node:http2";
import { createPrivateKey, createSign, type KeyObject } from "node:crypto";
import { readFile } from "node:fs/promises";

import type { SilentPushDispatch, SilentPushSender } from "./service.js";

type APNsEnvironment = "sandbox" | "production";

type APNsRequest = {
  host: string;
  path: string;
  headers: Record<string, string>;
  body: string;
};

type APNsResponse = {
  statusCode: number;
  body: string;
};

export interface APNsRequestTransport {
  send(request: APNsRequest): Promise<APNsResponse>;
}

export type APNsSilentPushSenderOptions = {
  teamId: string;
  keyId: string;
  bundleId: string;
  privateKeyPem: string;
  transport?: APNsRequestTransport;
  now?: () => number;
};

export class APNsSilentPushSender implements SilentPushSender {
  private readonly teamId: string;
  private readonly keyId: string;
  private readonly bundleId: string;
  private readonly privateKey: KeyObject;
  private readonly transport: APNsRequestTransport;
  private readonly now: () => number;
  private cachedAuthToken: { token: string; expiresAt: number } | null = null;

  constructor(opts: APNsSilentPushSenderOptions) {
    this.teamId = opts.teamId.trim();
    this.keyId = opts.keyId.trim();
    this.bundleId = opts.bundleId.trim();
    this.privateKey = createPrivateKey(opts.privateKeyPem);
    this.transport = opts.transport ?? new Http2APNsTransport();
    this.now = opts.now ?? (() => Date.now());
  }

  async sendSilentPush(dispatch: SilentPushDispatch): Promise<void> {
    const host = dispatch.device.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const authToken = this.authorizationToken();
    const body = JSON.stringify({
      aps: { "content-available": 1 },
      serverId: dispatch.payload.serverId,
      ...(dispatch.payload.cursorHint != null ? { cursorHint: dispatch.payload.cursorHint } : {}),
      changedSessionIds: dispatch.payload.changedSessionIds,
      ...(dispatch.payload.reason ? { reason: dispatch.payload.reason } : {}),
    });

    const response = await this.transport.send({
      host,
      path: `/3/device/${encodeURIComponent(dispatch.device.apnsToken)}`,
      headers: {
        authorization: `bearer ${authToken}`,
        "apns-push-type": "background",
        "apns-priority": "5",
        "apns-topic": this.bundleId,
        "content-type": "application/json",
      },
      body,
    });

    if (response.statusCode !== 200) {
      const detail = response.body.trim();
      throw new Error(`APNs push failed (${response.statusCode})${detail ? `: ${detail}` : ""}`);
    }
  }

  private authorizationToken(): string {
    const nowMs = this.now();
    if (this.cachedAuthToken && nowMs < this.cachedAuthToken.expiresAt) {
      return this.cachedAuthToken.token;
    }

    const issuedAt = Math.floor(nowMs / 1_000);
    const header = base64urlJSON({ alg: "ES256", kid: this.keyId });
    const payload = base64urlJSON({ iss: this.teamId, iat: issuedAt });
    const signingInput = `${header}.${payload}`;
    const signer = createSign("SHA256");
    signer.update(signingInput);
    signer.end();
    const signature = signer.sign({
      key: this.privateKey,
      dsaEncoding: "ieee-p1363",
    });
    const token = `${signingInput}.${toBase64url(signature)}`;
    this.cachedAuthToken = {
      token,
      expiresAt: nowMs + 50 * 60 * 1_000,
    };
    return token;
  }
}

class Http2APNsTransport implements APNsRequestTransport {
  async send(request: APNsRequest): Promise<APNsResponse> {
    return await new Promise((resolve, reject) => {
      const session = http2.connect(`https://${request.host}`);
      session.once("error", reject);

      const stream = session.request({
        ":method": "POST",
        ":path": request.path,
        ...request.headers,
      });

      let statusCode = 0;
      const chunks: Buffer[] = [];

      stream.setEncoding("utf8");
      stream.on("response", (headers) => {
        const raw = headers[http2.constants.HTTP2_HEADER_STATUS];
        statusCode = typeof raw === "number" ? raw : Number(raw ?? 0);
      });
      stream.on("data", (chunk) => {
        chunks.push(Buffer.from(chunk));
      });
      stream.once("error", (error) => {
        stream.close();
        session.close();
        reject(error);
      });
      stream.once("end", () => {
        stream.close();
        session.close();
        resolve({
          statusCode,
          body: Buffer.concat(chunks).toString("utf8"),
        });
      });
      stream.end(request.body);
    });
  }
}

export async function createAPNsSilentPushSenderFromEnv(
  env: NodeJS.ProcessEnv = process.env
): Promise<APNsSilentPushSender | null> {
  const teamId = normalizeOptionalString(env.APNS_TEAM_ID);
  const keyId = normalizeOptionalString(env.APNS_KEY_ID);
  const bundleId = normalizeOptionalString(env.APNS_BUNDLE_ID);
  const privateKeyPem = await loadPrivateKeyPem(env);
  if (!teamId || !keyId || !bundleId || !privateKeyPem) {
    return null;
  }
  return new APNsSilentPushSender({
    teamId,
    keyId,
    bundleId,
    privateKeyPem,
  });
}

async function loadPrivateKeyPem(env: NodeJS.ProcessEnv): Promise<string | null> {
  const inline = normalizeOptionalString(env.APNS_PRIVATE_KEY_PEM);
  if (inline) return inline.replace(/\\n/g, "\n");
  const path = normalizeOptionalString(env.APNS_PRIVATE_KEY_PATH);
  if (!path) return null;
  const raw = await readFile(path, "utf8");
  return normalizeOptionalString(raw);
}

function base64urlJSON(value: unknown): string {
  return toBase64url(Buffer.from(JSON.stringify(value)));
}

function toBase64url(buffer: Buffer): string {
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function normalizeOptionalString(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function decodeJwtPayloadForTesting(token: string): Record<string, unknown> {
  const segments = token.split(".");
  if (segments.length !== 3) throw new Error("Invalid JWT");
  return JSON.parse(Buffer.from(fromBase64url(segments[1]), "base64").toString("utf8")) as Record<string, unknown>;
}

function fromBase64url(value: string): string {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/");
  return padded + "=".repeat((4 - (padded.length % 4 || 4)) % 4);
}
