import test from "node:test";
import assert from "node:assert/strict";

import { BridgeService } from "../dist/index.js";

test("exports BridgeService", () => {
  assert.equal(typeof BridgeService, "function");
});

