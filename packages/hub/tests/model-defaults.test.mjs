import test from "node:test";
import assert from "node:assert/strict";

import { resolveHubModel, resolveHubProvider } from "../dist/index.js";

function withClearedModelEnv(fn) {
  const previousPrimary = process.env.EPOCH_MODEL_PRIMARY;
  const previousModel = process.env.EPOCH_MODEL;
  delete process.env.EPOCH_MODEL_PRIMARY;
  delete process.env.EPOCH_MODEL;
  try {
    fn();
  } finally {
    if (previousPrimary == null) delete process.env.EPOCH_MODEL_PRIMARY;
    else process.env.EPOCH_MODEL_PRIMARY = previousPrimary;
    if (previousModel == null) delete process.env.EPOCH_MODEL;
    else process.env.EPOCH_MODEL = previousModel;
  }
}

test("resolveHubProvider defaults to openai-codex/gpt-5.3-codex when unset", () => {
  withClearedModelEnv(() => {
    const resolved = resolveHubProvider(null);
    assert.equal(resolved.provider, "openai-codex");
    assert.equal(resolved.defaultModelId, "gpt-5.3-codex");
    assert.equal(resolved.ref, "openai-codex/gpt-5.3-codex");
  });
});

test("resolveHubModel defaults to openai-codex/gpt-5.3-codex when unset", () => {
  withClearedModelEnv(() => {
    const resolved = resolveHubModel(null);
    assert.equal(resolved.ok, true);
    assert.equal(resolved.provider, "openai-codex");
    assert.equal(resolved.modelId, "gpt-5.3-codex");
    assert.equal(resolved.ref, "openai-codex/gpt-5.3-codex");
  });
});

test("resolveHubProvider still respects EPOCH_MODEL_PRIMARY when set", () => {
  withClearedModelEnv(() => {
    process.env.EPOCH_MODEL_PRIMARY = "anthropic/claude-sonnet-4.5";
    const resolved = resolveHubProvider(null);
    assert.equal(resolved.provider, "anthropic");
    assert.equal(resolved.defaultModelId, "claude-sonnet-4.5");
    assert.equal(resolved.ref, "anthropic/claude-sonnet-4.5");
  });
});
