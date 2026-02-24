import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { ProtocolSchema, gatewayErrorCodes, gatewayEventNames, nodeMethods, operatorMethods } from "../dist/index.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const outPath = path.join(here, "..", "dist", "schema.json");
const gatewayOutPath = path.join(here, "..", "dist", "gateway.json");

await writeFile(outPath, JSON.stringify(ProtocolSchema, null, 2) + "\n", "utf8");
await writeFile(
  gatewayOutPath,
  JSON.stringify(
    {
      version: 1,
      operatorMethods,
      nodeMethods,
      eventNames: gatewayEventNames,
      errorCodes: gatewayErrorCodes,
    },
    null,
    2
  ) + "\n",
  "utf8"
);
