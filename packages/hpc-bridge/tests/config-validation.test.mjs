import test from "node:test";
import assert from "node:assert/strict";

import { validateHubUrl, validateWorkspaceRoot } from "../dist/index.js";

test("validateHubUrl accepts ws and wss", () => {
  assert.equal(validateHubUrl("ws://127.0.0.1:8787/ws"), null);
  assert.equal(validateHubUrl("wss://hub.example/ws"), null);
});

test("validateHubUrl rejects unsupported schemes", () => {
  assert.match(validateHubUrl("http://127.0.0.1:8787/ws"), /ws:\/\/ or wss:\/\//i);
  assert.match(validateHubUrl(""), /required/i);
});

test("validateWorkspaceRoot enforces absolute path", () => {
  assert.match(validateWorkspaceRoot(""), /required/i);
  assert.match(validateWorkspaceRoot("relative/path"), /absolute/i);
  assert.equal(validateWorkspaceRoot("/tmp/labos"), null);
});
