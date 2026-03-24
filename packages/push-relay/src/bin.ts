#!/usr/bin/env node
import { createAPNsSilentPushSenderFromEnv } from "./apns_sender.js";
import { NoopSilentPushSender, startPushRelayServer } from "./service.js";

const sharedSecret = process.env.EPOCH_PUSH_RELAY_SHARED_SECRET?.trim();
if (!sharedSecret) {
  console.error("Missing EPOCH_PUSH_RELAY_SHARED_SECRET");
  process.exit(1);
}

const host = process.env.HOST?.trim() || "0.0.0.0";
const port = Number(process.env.PORT ?? 8788);

try {
  const sender = await createAPNsSilentPushSenderFromEnv();
  if (!sender) {
    console.warn("APNs credentials not configured; starting push relay with no-op sender");
  }
  const app = await startPushRelayServer({
    sharedSecret,
    host,
    port,
    sender: sender ?? new NoopSilentPushSender(),
  });
  app.log.info({ host, port }, "Epoch Push Relay listening");
} catch (error) {
  console.error(error);
  process.exit(1);
}
