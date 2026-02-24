import { existsSync, readFileSync } from "node:fs";

const required = [
  new URL("../schema/ts/ClientRequest.ts", import.meta.url),
  new URL("../schema/ts/ServerNotification.ts", import.meta.url),
  new URL("../schema/json/ClientRequest.json", import.meta.url),
  new URL("../schema/json/ServerNotification.json", import.meta.url),
  new URL("../schema/json/codex_app_server_protocol.schemas.json", import.meta.url),
  new URL("../metadata.json", import.meta.url),
];

for (const file of required) {
  if (!existsSync(file)) {
    console.error(`Missing required schema artifact: ${file.pathname}`);
    process.exit(1);
  }
}

const metadataRaw = readFileSync(new URL("../metadata.json", import.meta.url), "utf8");
const metadata = JSON.parse(metadataRaw);
if (typeof metadata.codexVersion !== "string" || metadata.codexVersion.trim().length === 0) {
  console.error("metadata.json is missing codexVersion");
  process.exit(1);
}

console.log("codex-spec artifacts look valid.");
