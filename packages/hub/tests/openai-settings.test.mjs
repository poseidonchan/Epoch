import test from "node:test";
import assert from "node:assert/strict";

import {
  readOpenAISettingsStatus,
  resolveEffectiveOpenAIOcrModel,
  resolveOpenAIOcrModelFromConfig,
} from "../dist/index.js";

test("resolveOpenAIOcrModelFromConfig returns configured OCR model when present", () => {
  const model = resolveOpenAIOcrModelFromConfig({
    serverId: "s",
    token: "t",
    createdAt: new Date().toISOString(),
    openaiSettings: { ocrModel: "gpt-5.2-pro" },
  });
  assert.equal(model, "gpt-5.2-pro");
});

test("resolveEffectiveOpenAIOcrModel uses env then default when config is absent", () => {
  const original = process.env.EPOCH_PDF_OCR_MODEL;
  process.env.EPOCH_PDF_OCR_MODEL = "env-ocr";
  assert.equal(resolveEffectiveOpenAIOcrModel(null), "env-ocr");

  delete process.env.EPOCH_PDF_OCR_MODEL;
  assert.equal(resolveEffectiveOpenAIOcrModel(null), "gpt-5.2");

  if (original == null) {
    delete process.env.EPOCH_PDF_OCR_MODEL;
  } else {
    process.env.EPOCH_PDF_OCR_MODEL = original;
  }
});

test("readOpenAISettingsStatus includes OCR model and key configuration status", () => {
  const status = readOpenAISettingsStatus({
    serverId: "s",
    token: "t",
    createdAt: new Date().toISOString(),
    providerApiKeys: { openai: "sk-test" },
    providerApiKeyMetadata: { openai: { updatedAt: "2026-01-01T00:00:00.000Z", source: "epoch-ios" } },
    openaiSettings: { ocrModel: "gpt-5.2-chat-latest" },
  });
  assert.equal(status.configured, true);
  assert.equal(status.source, "epoch-ios");
  assert.equal(status.updatedAt, "2026-01-01T00:00:00.000Z");
  assert.equal(status.ocrModel, "gpt-5.2-chat-latest");
});
