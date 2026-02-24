import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";

const version = execSync("codex --version", { encoding: "utf8" }).trim();
const metadata = {
  generator: "codex app-server",
  codexVersion: version,
  generatedAt: new Date().toISOString(),
};

writeFileSync(new URL("../metadata.json", import.meta.url), `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
