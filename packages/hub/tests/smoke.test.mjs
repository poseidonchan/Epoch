import test from "node:test";
import assert from "node:assert/strict";

import { startHub } from "../dist/index.js";

test("exports startHub()", () => {
  assert.equal(typeof startHub, "function");
});

