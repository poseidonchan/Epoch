import test from "node:test";
import assert from "node:assert/strict";

import { createPushRelayService, MemoryPushRelayStore } from "../dist/index.js";

test("push relay upserts registrations and applies heartbeat updates", async () => {
  const store = new MemoryPushRelayStore();
  const relay = createPushRelayService({
    sharedSecret: "relay_secret",
    store,
  });

  try {
    let response = await relay.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: {
        "x-epoch-shared-secret": "relay_secret",
      },
      payload: {
        serverId: "srv_a",
        installationId: "install_a",
        apnsToken: "apns_1",
        environment: "sandbox",
        deviceName: "Epoch iPhone",
        platform: "iOS",
      },
    });
    assert.equal(response.statusCode, 200);
    assert.equal(store.listDevices("srv_a").length, 1);
    assert.equal(store.listDevices("srv_a")[0].apnsToken, "apns_1");

    response = await relay.inject({
      method: "POST",
      url: "/v1/devices/heartbeat",
      headers: {
        authorization: "Bearer relay_secret",
      },
      payload: {
        serverId: "srv_a",
        installationId: "install_a",
        apnsToken: "apns_2",
      },
    });
    assert.equal(response.statusCode, 200);
    assert.equal(store.listDevices("srv_a")[0].apnsToken, "apns_2");
  } finally {
    await relay.close();
  }
});

test("push relay collapses duplicate live-session fanout within dedupe window", async () => {
  const store = new MemoryPushRelayStore();
  const delivered = [];
  let currentNow = 10_000;

  const relay = createPushRelayService({
    sharedSecret: "relay_secret",
    store,
    now: () => currentNow,
    sender: {
      async sendSilentPush(dispatch) {
        delivered.push(dispatch);
      },
    },
  });

  try {
    await relay.inject({
      method: "POST",
      url: "/v1/devices/register",
      headers: {
        "x-epoch-shared-secret": "relay_secret",
      },
      payload: {
        serverId: "srv_a",
        installationId: "install_a",
        apnsToken: "apns_1",
        environment: "sandbox",
        deviceName: "Epoch iPhone",
        platform: "iOS",
      },
    });

    const payload = {
      serverId: "srv_a",
      cursorHint: 44,
      changedSessionIds: ["session_1"],
      reason: "turn/completed",
    };
    let response = await relay.inject({
      method: "POST",
      url: "/v1/events/live-session",
      headers: {
        "x-epoch-shared-secret": "relay_secret",
      },
      payload,
    });
    assert.equal(response.statusCode, 200);
    assert.equal(JSON.parse(response.body).delivered, 1);
    assert.equal(delivered.length, 1);

    response = await relay.inject({
      method: "POST",
      url: "/v1/events/live-session",
      headers: {
        "x-epoch-shared-secret": "relay_secret",
      },
      payload,
    });
    assert.equal(JSON.parse(response.body).delivered, 0);
    assert.equal(delivered.length, 1);

    currentNow += 6_000;
    response = await relay.inject({
      method: "POST",
      url: "/v1/events/live-session",
      headers: {
        "x-epoch-shared-secret": "relay_secret",
      },
      payload,
    });
    assert.equal(JSON.parse(response.body).delivered, 1);
    assert.equal(delivered.length, 2);
  } finally {
    await relay.close();
  }
});
