import test from "node:test";
import assert from "node:assert/strict";

/**
 * These tests validate the token usage extraction logic used in
 * CodexRpcRouter.persistAndSendNotification() for thread/tokenUsage/updated.
 *
 * The codex app-server sends v2 nested format (ThreadTokenUsage):
 *   { total: TokenUsageBreakdown, last: TokenUsageBreakdown, modelContextWindow: number | null }
 *
 * The hub must extract contextWindowTokens, usedInputTokens, usedTokens from this format
 * while maintaining backward compatibility with legacy flat and v1 snake_case formats.
 */

function normalizeNumericTokenCount(raw) {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return Math.max(0, Math.floor(raw));
  }
  if (typeof raw === "string" && raw.trim()) {
    const parsed = Number(raw);
    if (Number.isFinite(parsed)) {
      return Math.max(0, Math.floor(parsed));
    }
  }
  return null;
}

/**
 * Replicates the extraction logic from router.ts persistAndSendNotification
 */
function extractTokenUsage(tokenUsage) {
  const totalBreakdown = (tokenUsage.total != null && typeof tokenUsage.total === "object") ? tokenUsage.total : undefined;
  const lastBreakdown = (tokenUsage.last != null && typeof tokenUsage.last === "object") ? tokenUsage.last : undefined;
  const totalBreakdownV1 = (tokenUsage.total_token_usage != null && typeof tokenUsage.total_token_usage === "object") ? tokenUsage.total_token_usage : undefined;
  const lastBreakdownV1 = (tokenUsage.last_token_usage != null && typeof tokenUsage.last_token_usage === "object") ? tokenUsage.last_token_usage : undefined;

  const contextWindowTokens = normalizeNumericTokenCount(
    tokenUsage.modelContextWindow ?? tokenUsage.model_context_window ??
    tokenUsage.contextWindow ?? tokenUsage.contextWindowTokens
  );
  const usedInputTokens = normalizeNumericTokenCount(
    lastBreakdown?.inputTokens ?? lastBreakdownV1?.input_tokens ??
    tokenUsage.inputTokens ?? tokenUsage.totalInputTokens
  );
  const usedTokens = normalizeNumericTokenCount(
    lastBreakdown?.totalTokens ?? lastBreakdownV1?.total_tokens ??
    totalBreakdown?.totalTokens ?? totalBreakdownV1?.total_tokens ??
    tokenUsage.totalTokens ?? tokenUsage.totalInputTokens ?? tokenUsage.inputTokens
  );

  return { contextWindowTokens, usedInputTokens, usedTokens };
}

test("v2 token usage nested structure is correctly parsed", () => {
  // v2 camelCase format from codex app-server
  const result = extractTokenUsage({
    total: {
      totalTokens: 50000,
      inputTokens: 40000,
      cachedInputTokens: 5000,
      outputTokens: 10000,
      reasoningOutputTokens: 2000,
    },
    last: {
      totalTokens: 12000,
      inputTokens: 8000,
      cachedInputTokens: 1000,
      outputTokens: 4000,
      reasoningOutputTokens: 500,
    },
    modelContextWindow: 200000,
  });

  assert.equal(result.contextWindowTokens, 200000, "contextWindowTokens from modelContextWindow");
  assert.equal(result.usedInputTokens, 8000, "usedInputTokens from last.inputTokens");
  assert.equal(result.usedTokens, 12000, "usedTokens from last.totalTokens");

  // Verify remaining calculation matches what server.ts does
  const remainingTokens = Math.max(0, result.contextWindowTokens - result.usedInputTokens);
  assert.equal(remainingTokens, 192000);
});

test("v1 snake_case token usage nested structure is correctly parsed", () => {
  const result = extractTokenUsage({
    total_token_usage: {
      total_tokens: 45000,
      input_tokens: 35000,
      cached_input_tokens: 3000,
      output_tokens: 10000,
      reasoning_output_tokens: 1000,
    },
    last_token_usage: {
      total_tokens: 10000,
      input_tokens: 7000,
      cached_input_tokens: 500,
      output_tokens: 3000,
      reasoning_output_tokens: 200,
    },
    model_context_window: 128000,
  });

  assert.equal(result.contextWindowTokens, 128000, "contextWindowTokens from model_context_window");
  assert.equal(result.usedInputTokens, 7000, "usedInputTokens from last_token_usage.input_tokens");
  assert.equal(result.usedTokens, 10000, "usedTokens from last_token_usage.total_tokens");
});

test("legacy flat token usage format still works", () => {
  const result = extractTokenUsage({
    contextWindow: 150000,
    inputTokens: 9000,
    totalTokens: 15000,
    model: "gpt-4",
  });

  assert.equal(result.contextWindowTokens, 150000, "contextWindowTokens from contextWindow (legacy)");
  assert.equal(result.usedInputTokens, 9000, "usedInputTokens from inputTokens (legacy)");
  assert.equal(result.usedTokens, 15000, "usedTokens from totalTokens (legacy)");
});
