import test from "node:test";
import assert from "node:assert/strict";

import { buildHubPairingPayloadURL, resolvePairingWSURL } from "../dist/index.js";

test("buildHubPairingPayloadURL encodes required pairing fields", () => {
  const raw = buildHubPairingPayloadURL({
    wsURL: "ws://10.0.0.8:8787/ws",
    token: "tok_abc",
    serverId: "server_1",
  });
  const parsed = new URL(raw);

  assert.equal(parsed.protocol, "epoch:");
  assert.equal(parsed.hostname, "pair");
  assert.equal(parsed.searchParams.get("v"), "1");
  assert.equal(parsed.searchParams.get("ws"), "ws://10.0.0.8:8787/ws");
  assert.equal(parsed.searchParams.get("token"), "tok_abc");
  assert.equal(parsed.searchParams.get("serverId"), "server_1");
});

test("buildHubPairingPayloadURL encodes optional server name", () => {
  const raw = buildHubPairingPayloadURL({
    wsURL: "ws://10.0.0.8:8787/ws",
    token: "tok_abc",
    serverId: "server_1",
    name: "GPU Login 01",
  });
  const parsed = new URL(raw);

  assert.equal(parsed.searchParams.get("name"), "GPU Login 01");
});

test("resolvePairingWSURL prefers EPOCH_PAIR_WS_URL when set", async () => {
  const result = await resolvePairingWSURL({
    env: {
      EPOCH_PAIR_WS_URL: "wss://hub.example/ws",
      EPOCH_PORT: "9999",
    },
  });

  assert.equal(result.wsURL, "wss://hub.example/ws");
  assert.equal(result.source, "env");
});

test("resolvePairingWSURL prefers saved publicWsUrl when env override is absent", async () => {
  const result = await resolvePairingWSURL({
    env: {
      EPOCH_PORT: "8787",
    },
    config: {
      publicWsUrl: "wss://phone-reachable.example/ws",
    },
  });

  assert.equal(result.wsURL, "wss://phone-reachable.example/ws");
  assert.equal(result.source, "config");
});

test("resolvePairingWSURL prefers detected Tailscale DNS name when config is absent", async () => {
  const result = await resolvePairingWSURL({
    env: {
      EPOCH_PORT: "8787",
    },
    detectTailscalePairingAddress: async () => ({
      dnsName: "login01.epoch.ts.net.",
      ip: "100.90.12.34",
    }),
  });

  assert.equal(result.wsURL, "ws://login01.epoch.ts.net:8787/ws");
  assert.equal(result.source, "tailscale");
});

test("resolvePairingWSURL falls back to loopback and warning when no explicit public URL exists", async () => {
  const result = await resolvePairingWSURL({
    env: {
      EPOCH_PORT: "8787",
    },
    detectTailscalePairingAddress: async () => null,
  });

  assert.equal(result.wsURL, "ws://127.0.0.1:8787/ws");
  assert.equal(result.source, "loopback");
  assert.ok(result.warning);
});
