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

test("resolvePairingWSURL prefers EPOCH_PAIR_WS_URL when set", () => {
  const result = resolvePairingWSURL({
    env: {
      EPOCH_PAIR_WS_URL: "wss://hub.example/ws",
      EPOCH_PORT: "9999",
    },
    networkInterfaces: () => ({
      en0: [{ address: "192.168.0.20", family: "IPv4", internal: false }],
    }),
  });

  assert.equal(result.wsURL, "wss://hub.example/ws");
  assert.equal(result.source, "env");
});

test("resolvePairingWSURL prefers saved publicWsUrl when env override is absent", () => {
  const result = resolvePairingWSURL({
    env: {
      EPOCH_PORT: "8787",
    },
    config: {
      publicWsUrl: "wss://phone-reachable.example/ws",
    },
    networkInterfaces: () => ({
      lo0: [{ address: "127.0.0.1", family: "IPv4", internal: true }],
      en0: [{ address: "10.1.2.3", family: "IPv4", internal: false }],
    }),
  });

  assert.equal(result.wsURL, "wss://phone-reachable.example/ws");
  assert.equal(result.source, "config");
});

test("resolvePairingWSURL falls back to loopback and warning when no explicit public URL exists", () => {
  const result = resolvePairingWSURL({
    env: {
      EPOCH_PORT: "8787",
    },
    networkInterfaces: () => ({
      en0: [{ address: "10.1.2.3", family: "IPv4", internal: false }],
      lo0: [{ address: "::1", family: "IPv6", internal: true }],
    }),
  });

  assert.equal(result.wsURL, "ws://127.0.0.1:8787/ws");
  assert.equal(result.source, "loopback");
  assert.ok(result.warning);
});
