import test from "node:test";
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { decryptEncryptedApnsKey, importEncryptedApnsKey, loadOrCreateHubConfig, saveHubConfig } from "../dist/index.js";

test("loadOrCreateHubConfig imports workspaceRoot from legacy bridge config on first direct-connect setup", async () => {
  const originalHome = process.env.HOME;
  const homeDir = await mkdtemp(path.join(os.tmpdir(), "epoch-home-"));
  const stateDir = path.join(homeDir, ".epoch");
  const legacyDir = path.join(homeDir, ".epoch-bridge");

  process.env.HOME = homeDir;
  await mkdir(legacyDir, { recursive: true });
  await writeFile(
    path.join(legacyDir, "config.json"),
    JSON.stringify(
      {
        hubUrl: "wss://legacy.example/ws",
        token: "legacy_token",
        nodeId: "legacy_node",
        workspaceRoot: "/hpc/projects/epoch",
        defaults: {
          partition: "gpu",
        },
      },
      null,
      2
    ) + "\n",
    "utf8"
  );

  try {
    const config = await loadOrCreateHubConfig({ stateDir, allowCreate: true });
    assert.equal(config?.workspaceRoot, "/hpc/projects/epoch");
    assert.equal(config?.publicWsUrl, null);
  } finally {
    if (originalHome == null) delete process.env.HOME;
    else process.env.HOME = originalHome;
  }
});

test("saveHubConfig persists direct-connect publicWsUrl and embedded push metadata", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-config-save-"));

  await saveHubConfig({
    stateDir,
    config: {
      serverId: "server_save_1",
      token: "token_save_1",
      createdAt: "2026-03-23T00:00:00.000Z",
      workspaceRoot: "/srv/epoch/workspace",
      publicWsUrl: "wss://edge.example/ws",
      pushEnabled: true,
      push: {
        teamId: "TEAM1234",
        keyId: "KEY1234",
        bundleId: "dev.epoch.app",
        encryptedKeyPath: "/srv/epoch/.epoch/secrets/apns-key.enc",
      },
    },
  });

  const raw = JSON.parse(await readFile(path.join(stateDir, "config.json"), "utf8"));
  assert.equal(raw.workspaceRoot, "/srv/epoch/workspace");
  assert.equal(raw.publicWsUrl, "wss://edge.example/ws");
  assert.equal(raw.pushEnabled, true);
  assert.deepEqual(raw.push, {
    teamId: "TEAM1234",
    keyId: "KEY1234",
    bundleId: "dev.epoch.app",
    encryptedKeyPath: "/srv/epoch/.epoch/secrets/apns-key.enc",
  });
});

test("importEncryptedApnsKey encrypts and decrypts a local APNs private key", async () => {
  const stateDir = await mkdtemp(path.join(os.tmpdir(), "epoch-push-key-"));
  const sourcePath = path.join(stateDir, "AuthKey_TEST123.p8");
  const privateKey = [
    "-----BEGIN PRIVATE KEY-----",
    "VGhpcyBpcyBhIHRlc3Qga2V5Lg==",
    "-----END PRIVATE KEY-----",
  ].join("\n");
  await writeFile(sourcePath, privateKey + "\n", "utf8");

  const imported = await importEncryptedApnsKey({
    stateDir,
    sourcePath,
    passphrase: "local passphrase",
  });
  const decrypted = await decryptEncryptedApnsKey({
    encryptedKeyPath: imported.encryptedKeyPath,
    passphrase: "local passphrase",
  });

  assert.equal(decrypted, privateKey);
});
