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

test("projects.create expands tilde-rooted workspace paths", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-gateway-project-workspace-"));
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

    await connectOperator(ws, frames, config);

    ws.send(
      JSON.stringify({
        type: "req",
        id: "project_create_1",
        method: "projects.create",
        params: {
          name: "Gateway Home Project",
          workspacePath: "~/Documents/GitHub",
        },
      })
    );

    const created = await frames.next((frame) => frame.type === "res" && frame.id === "project_create_1");
    assert.equal(created.ok, true);
    assert.equal(created.payload.project.hpcWorkspacePath, path.join(os.homedir(), "Documents", "GitHub"));
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

test("projects.create rejects relative workspace paths that are not tilde-rooted", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-gateway-project-relative-"));
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

    await connectOperator(ws, frames, config);

    ws.send(
      JSON.stringify({
        type: "req",
        id: "project_create_relative",
        method: "projects.create",
        params: {
          name: "Gateway Relative Project",
          workspacePath: "Documents/GitHub",
        },
      })
    );

    const response = await frames.next((frame) => frame.type === "res" && frame.id === "project_create_relative");
    assert.equal(response.ok, false);
    assert.match(String(response.error?.message ?? ""), /workspacePath/i);
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

async function connectOperator(ws, frames, config) {
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
          id: "dev_project_workspace_test",
          name: "Project Workspace Test Device",
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
}

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
