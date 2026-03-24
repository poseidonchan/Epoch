import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import * as hub from "../dist/index.js";

class FakeWebSocket {
  constructor() {
    this.handlers = new Map();
    this.sent = [];
  }

  on(event, handler) {
    this.handlers.set(event, handler);
  }

  send(payload) {
    this.sent.push(payload);
  }

  emit(event, value) {
    const handler = this.handlers.get(event);
    if (handler) handler(value);
  }

  close() {
    this.emit("close");
  }
}

test("detached runtime is reaped after idle TTL when no turns are active", async () => {
  const originalTtl = process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS;
  process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS = "20";

  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-codex-runtime-idle-"));
  const pool = await hub.connectDb(path.join(stateDir, "epoch.sqlite"));

  try {
    await hub.runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    const config = await hub.loadOrCreateHubConfig({ stateDir, allowCreate: true });
    const ws = new FakeWebSocket();

    hub.attachCodexTransport({
      ws,
      request: {
        url: "/codex",
        headers: { authorization: "Bearer tok_idle_1", host: "localhost" },
      },
      config,
      stateDir,
      pool,
    });

    assert.equal(hub.runtimeCountForTesting(), 1);
    ws.emit("close");
    await sleep(40);
    assert.equal(hub.runtimeCountForTesting(), 0);
  } finally {
    await hub.closeAllCodexTransports();
    await pool.end();
    await rm(stateDir, { recursive: true, force: true });
    if (originalTtl == null) delete process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS;
    else process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS = originalTtl;
  }
});

test("detached runtime stays alive while its engine reports active turns", async () => {
  const originalTtl = process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS;
  process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS = "20";

  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-codex-runtime-active-"));
  const pool = await hub.connectDb(path.join(stateDir, "epoch.sqlite"));
  let activeTurns = 1;

  try {
    await hub.runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    const config = await hub.loadOrCreateHubConfig({ stateDir, allowCreate: true });
    const ws = new FakeWebSocket();

    hub.attachCodexTransport({
      ws,
      request: {
        url: "/codex",
        headers: { authorization: "Bearer tok_active_1", host: "localhost" },
      },
      config,
      stateDir,
      pool,
      createEngines: () => ({
        getEngine: async () => {
          throw new Error("not used");
        },
        close: async () => {},
        activeTurnCount: () => activeTurns,
      }),
    });

    assert.equal(hub.runtimeCountForTesting(), 1);
    ws.emit("close");
    await sleep(40);
    assert.equal(hub.runtimeCountForTesting(), 1);

    activeTurns = 0;
    await sleep(40);
    assert.equal(hub.runtimeCountForTesting(), 0);
  } finally {
    await hub.closeAllCodexTransports();
    await pool.end();
    await rm(stateDir, { recursive: true, force: true });
    if (originalTtl == null) delete process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS;
    else process.env.EPOCH_CODEX_RUNTIME_IDLE_TTL_MS = originalTtl;
  }
});

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
