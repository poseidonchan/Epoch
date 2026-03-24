import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";

import { APNsSilentPushSender, decodeJwtPayloadForTesting } from "../dist/index.js";

function privateKeyPem() {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return privateKey.export({ format: "pem", type: "pkcs8" }).toString();
}

test("APNs sender builds a silent sandbox push payload", async () => {
  const requests = [];
  const sender = new APNsSilentPushSender({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "dev.epoch.app",
    privateKeyPem: privateKeyPem(),
    now: () => 1_700_000_000_000,
    transport: {
      async send(request) {
        requests.push(request);
        return { statusCode: 200, body: "" };
      },
    },
  });

  await sender.sendSilentPush({
    device: {
      serverId: "srv_a",
      installationId: "install_a",
      apnsToken: "apns_token",
      environment: "sandbox",
      deviceName: "Epoch iPhone",
      platform: "iOS",
      updatedAt: 1,
    },
    payload: {
      serverId: "srv_a",
      cursorHint: 44,
      changedSessionIds: ["session_1"],
      reason: "turn/completed",
    },
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].host, "api.sandbox.push.apple.com");
  assert.equal(requests[0].path, "/3/device/apns_token");
  assert.equal(requests[0].headers["apns-push-type"], "background");
  assert.equal(requests[0].headers["apns-priority"], "5");
  assert.equal(requests[0].headers["apns-topic"], "dev.epoch.app");

  const jwt = requests[0].headers.authorization.replace(/^bearer\s+/i, "");
  const payload = decodeJwtPayloadForTesting(jwt);
  assert.equal(payload.iss, "TEAM123456");
  assert.equal(payload.iat, 1_700_000_000);

  assert.deepEqual(JSON.parse(requests[0].body), {
    aps: { "content-available": 1 },
    serverId: "srv_a",
    cursorHint: 44,
    changedSessionIds: ["session_1"],
    reason: "turn/completed",
  });
});

test("APNs sender switches to production host for production devices", async () => {
  const requests = [];
  const sender = new APNsSilentPushSender({
    teamId: "TEAM123456",
    keyId: "KEY1234567",
    bundleId: "dev.epoch.app",
    privateKeyPem: privateKeyPem(),
    transport: {
      async send(request) {
        requests.push(request);
        return { statusCode: 200, body: "" };
      },
    },
  });

  await sender.sendSilentPush({
    device: {
      serverId: "srv_prod",
      installationId: "install_prod",
      apnsToken: "prod_token",
      environment: "production",
      deviceName: "Epoch iPhone",
      platform: "iOS",
      updatedAt: 1,
    },
    payload: {
      serverId: "srv_prod",
      changedSessionIds: [],
    },
  });

  assert.equal(requests.length, 1);
  assert.equal(requests[0].host, "api.push.apple.com");
});
