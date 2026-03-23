import qrcode from "qrcode-terminal";

export type PairingWSURLSource = "env" | "config" | "loopback";

export type PairingWSURLResolution = {
  wsURL: string;
  source: PairingWSURLSource;
  warning?: string;
};

type PairingWSResolverOptions = {
  env?: NodeJS.ProcessEnv;
  config?: { publicWsUrl?: string | null };
  networkInterfaces?: () => Record<string, Array<{ address: string; family: string | number; internal: boolean }> | undefined>;
  defaultPort?: number;
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

export function resolvePairingWSURL(opts: PairingWSResolverOptions = {}): PairingWSURLResolution {
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

  return {
    wsURL: `ws://127.0.0.1:${port}/ws`,
    source: "loopback",
    warning: "No explicit public WS URL is configured. Pairing QR uses loopback (127.0.0.1).",
  };
}

export function buildHubPairingPayloadURL(opts: { wsURL: string; token: string; serverId?: string }): string {
  const wsURL = String(opts.wsURL ?? "").trim();
  const token = String(opts.token ?? "").trim();
  const serverId = String(opts.serverId ?? "").trim();
  const payload = new URL("epoch://pair");
  payload.searchParams.set("v", "1");
  payload.searchParams.set("ws", wsURL);
  payload.searchParams.set("token", token);
  if (serverId) {
    payload.searchParams.set("serverId", serverId);
  }
  return payload.toString();
}

export function renderHubPairingQRCode(payloadURL: string, logger: (line: string) => void = console.log): void {
  qrcode.generate(payloadURL, { small: true }, (text) => {
    logger(String(text));
  });
}
