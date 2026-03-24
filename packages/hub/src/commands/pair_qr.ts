import { execFile } from "node:child_process";
import { promisify } from "node:util";

import qrcode from "qrcode-terminal";

const execFileAsync = promisify(execFile);

export type PairingWSURLSource = "env" | "config" | "tailscale" | "loopback";

export type PairingWSURLResolution = {
  wsURL: string;
  source: PairingWSURLSource;
  warning?: string;
};

export type TailscalePairingAddress = {
  dnsName?: string | null;
  ip?: string | null;
};

type PairingWSResolverOptions = {
  env?: NodeJS.ProcessEnv;
  config?: { publicWsUrl?: string | null };
  defaultPort?: number;
  detectTailscalePairingAddress?: () => Promise<TailscalePairingAddress | null>;
};

function normalizePairingWSURL(raw: string): string {
  let value = raw.trim();
  if (!value) return value;

  if (!value.includes("://")) {
    value = `ws://${value}`;
  }

  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return raw.trim();
  }

  const scheme = parsed.protocol.toLowerCase();
  if (scheme === "http:") {
    parsed.protocol = "ws:";
  } else if (scheme === "https:") {
    parsed.protocol = "wss:";
  }

  if (!parsed.pathname || parsed.pathname === "/") {
    parsed.pathname = "/ws";
  }

  return parsed.toString();
}

export async function detectTailscalePairingAddress(): Promise<TailscalePairingAddress | null> {
  try {
    const { stdout } = await execFileAsync("tailscale", ["status", "--json"], {
      env: process.env,
      maxBuffer: 2 * 1024 * 1024,
    });
    const parsed = JSON.parse(String(stdout ?? "")) as {
      Self?: {
        DNSName?: unknown;
        TailscaleIPs?: unknown;
      };
    };
    const self = parsed?.Self;
    if (!self || typeof self !== "object") {
      return null;
    }

    const rawDnsName = typeof self.DNSName === "string" ? self.DNSName.trim() : "";
    const dnsName = rawDnsName.replace(/\.+$/, "") || null;
    const ip = Array.isArray(self.TailscaleIPs)
      ? self.TailscaleIPs.find((value) => typeof value === "string" && value.includes(".")) as string | undefined
      : undefined;

    if (!dnsName && !ip) {
      return null;
    }

    return {
      dnsName,
      ip: ip?.trim() || null,
    };
  } catch {
    return null;
  }
}

function buildPairingWSURL(host: string, port: number): string {
  return normalizePairingWSURL(`ws://${host}:${port}/ws`);
}

export async function resolvePairingWSURL(opts: PairingWSResolverOptions = {}): Promise<PairingWSURLResolution> {
  const env = opts.env ?? process.env;
  const configured = String(env.EPOCH_PAIR_WS_URL ?? "").trim();
  if (configured) {
    return {
      wsURL: normalizePairingWSURL(configured),
      source: "env",
    };
  }

  const configUrl = String(opts.config?.publicWsUrl ?? "").trim();
  if (configUrl) {
    return {
      wsURL: normalizePairingWSURL(configUrl),
      source: "config",
    };
  }

  const portRaw = String(env.EPOCH_PORT ?? "").trim();
  const portValue = Number(portRaw);
  const port = Number.isFinite(portValue) && portValue > 0 ? Math.floor(portValue) : (opts.defaultPort ?? 8787);
  const detectTailscale = opts.detectTailscalePairingAddress ?? detectTailscalePairingAddress;
  const tailscale = await detectTailscale();
  const tailscaleHost = String(tailscale?.dnsName ?? "").trim().replace(/\.+$/, "") || String(tailscale?.ip ?? "").trim();
  if (tailscaleHost) {
    return {
      wsURL: buildPairingWSURL(tailscaleHost, port),
      source: "tailscale",
    };
  }

  return {
    wsURL: buildPairingWSURL("127.0.0.1", port),
    source: "loopback",
    warning: "No explicit public WS URL is configured. Pairing QR uses loopback (127.0.0.1).",
  };
}

export function buildHubPairingPayloadURL(opts: { wsURL: string; token: string; serverId?: string; name?: string }): string {
  const wsURL = String(opts.wsURL ?? "").trim();
  const token = String(opts.token ?? "").trim();
  const serverId = String(opts.serverId ?? "").trim();
  const name = String(opts.name ?? "").trim();
  const payload = new URL("epoch://pair");
  payload.searchParams.set("v", "1");
  payload.searchParams.set("ws", wsURL);
  payload.searchParams.set("token", token);
  if (serverId) {
    payload.searchParams.set("serverId", serverId);
  }
  if (name) {
    payload.searchParams.set("name", name);
  }
  return payload.toString();
}

export function renderHubPairingQRCode(payloadURL: string, logger: (line: string) => void = console.log): void {
  qrcode.generate(payloadURL, { small: true }, (text) => {
    logger(String(text));
  });
}
