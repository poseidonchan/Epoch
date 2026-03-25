import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { createHmac } from "node:crypto";
import { createServer } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import WebSocket from "ws";

import * as hub from "../dist/index.js";

test("sessions.permission.set broadcasts sessions.permission.updated", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-gateway-session-permission-"));
  const pool = await hub.connectDb(path.join(stateDir, "epoch.sqlite"));

  let handle = null;
  let ws = null;

  try {
    await hub.runMigrations(pool, { migrationsDir: new URL("../migrations/", import.meta.url) });
    const config = await hub.loadOrCreateHubConfig({ stateDir, allowCreate: true });
    const port = await getAvailablePort();

    handle = await hub.startHub({
      port,
      host: "127.0.0.1",
      config,
      stateDir,
      pool,
    });

    ws = new WebSocket(`ws://127.0.0.1:${port}/ws`);
    const frames = createFrameQueue(ws);
    await once(ws, "open");

    const challenge = await frames.next((frame) => frame.type === "event" && frame.event === "connect.challenge");
    const signature = createHmac("sha256", config.token).update(String(challenge.payload.nonce)).digest("base64url");

    ws.send(
      JSON.stringify({
        type: "req",
        id: "connect_1",
        method: "connect",
        params: {
          role: "operator",
          minProtocol: 1,
          maxProtocol: 1,
          auth: {
            token: config.token,
            signature,
          },
          device: {
            id: "dev_permission_test",
            name: "Permission Test Device",
            platform: "test",
          },
          client: {
            name: "hub-test",
            version: "0.1.0",
          },
          scopes: [],
        },
      })
    );

    const connected = await frames.next((frame) => frame.type === "res" && frame.id === "connect_1");
    assert.equal(connected.ok, true);

    ws.send(
      JSON.stringify({
        type: "req",
        id: "project_create_1",
        method: "projects.create",
        params: {
          name: "Permission Project",
        },
      })
    );
    const projectCreated = await frames.next((frame) => frame.type === "res" && frame.id === "project_create_1");
    assert.equal(projectCreated.ok, true);
    const projectId = String(projectCreated.payload.project.id);

    ws.send(
      JSON.stringify({
        type: "req",
        id: "session_create_1",
        method: "sessions.create",
        params: {
          projectId,
          title: "Permission Session",
        },
      })
    );
    const sessionCreated = await frames.next((frame) => frame.type === "res" && frame.id === "session_create_1");
    assert.equal(sessionCreated.ok, true);
    const sessionId = String(sessionCreated.payload.session.id);

    ws.send(
      JSON.stringify({
        type: "req",
        id: "permission_set_1",
        method: "sessions.permission.set",
        params: {
          projectId,
          sessionId,
          level: "full",
        },
      })
    );

    const permissionResponse = await frames.next((frame) => frame.type === "res" && frame.id === "permission_set_1");
    assert.equal(permissionResponse.ok, true);
    assert.equal(permissionResponse.payload.level, "full");

    const permissionEvent = await frames.next(
      (frame) =>
        frame.type === "event"
        && frame.event === "sessions.permission.updated"
        && frame.payload.projectId === projectId
        && frame.payload.sessionId === sessionId
    );

    assert.equal(permissionEvent.payload.level, "full");
    assert.match(String(permissionEvent.payload.updatedAt), /^\d{4}-\d{2}-\d{2}T/);
  } finally {
    if (ws) {
      ws.close();
      await once(ws, "close").catch(() => {});
    }
    if (handle) {
      await handle.close();
    }
    await pool.end();
    await rm(stateDir, { recursive: true, force: true });
  }
});

function createFrameQueue(ws) {
  const queued = [];
  const pending = [];

  ws.on("message", (raw) => {
    const frame = JSON.parse(String(raw));
    const matchIndex = pending.findIndex((entry) => entry.predicate(frame));
    if (matchIndex >= 0) {
      const [{ resolve, timeout }] = pending.splice(matchIndex, 1);
      clearTimeout(timeout);
      resolve(frame);
      return;
    }
    queued.push(frame);
  });

  return {
    next(predicate, timeoutMs = 2_000) {
      const queuedIndex = queued.findIndex((frame) => predicate(frame));
      if (queuedIndex >= 0) {
        return Promise.resolve(queued.splice(queuedIndex, 1)[0]);
      }

      return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
          const pendingIndex = pending.findIndex((entry) => entry.resolve === resolve);
          if (pendingIndex >= 0) {
            pending.splice(pendingIndex, 1);
          }
          reject(new Error("Timed out waiting for matching frame"));
        }, timeoutMs);
        pending.push({ predicate, resolve, timeout });
      });
    },
  };
}

async function getAvailablePort() {
  return await new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : null;
      server.close((err) => {
        if (err) {
          reject(err);
          return;
        }
        resolve(port);
      });
    });
  });
}
