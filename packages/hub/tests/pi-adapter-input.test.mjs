import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, writeFile, rm } from "node:fs/promises";

import { buildPiHistoryMessages, buildPiUserContentFromCodexInput } from "../dist/index.js";

const ONE_PIXEL_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII=";

test("buildPiUserContentFromCodexInput converts localImage entries into image blocks", async () => {
  const tempDir = await mkdtemp(path.join(os.tmpdir(), "labos-pi-image-"));
  const filePath = path.join(tempDir, "sample.png");
  try {
    await writeFile(filePath, Buffer.from(ONE_PIXEL_PNG_BASE64, "base64"));

    const content = await buildPiUserContentFromCodexInput([
      { type: "text", text: "Read this pic", text_elements: [] },
      { type: "localImage", path: filePath },
    ]);

    assert.equal(Array.isArray(content), true);
    assert.equal(content.length, 2);
    assert.deepEqual(content[0], { type: "text", text: "Read this pic" });
    assert.equal(content[1].type, "image");
    assert.equal(content[1].mimeType, "image/png");
    assert.match(content[1].data, /^[A-Za-z0-9+/=]+$/);
    assert.equal(content[1].data.length > 10, true);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
});

test("buildPiUserContentFromCodexInput keeps text and does not leak unresolved local path text", async () => {
  const missingPath = path.join(os.tmpdir(), "does-not-exist", "missing.png");
  const content = await buildPiUserContentFromCodexInput([
    { type: "text", text: "What is in this image?", text_elements: [] },
    { type: "localImage", path: missingPath },
  ]);

  assert.deepEqual(content, [{ type: "text", text: "What is in this image?" }]);
  const combined = content.map((part) => ("text" in part ? part.text : "")).join("\n");
  assert.equal(combined.includes(missingPath), false);
});

test("buildPiHistoryMessages emits assistant history as content blocks", async () => {
  const history = await buildPiHistoryMessages([
    {
      id: "turn_prev",
      status: "completed",
      error: null,
      items: [
        {
          type: "userMessage",
          id: "item_user_1",
          content: [{ type: "text", text: "Who are you?", text_elements: [] }],
        },
        {
          type: "agentMessage",
          id: "item_agent_1",
          text: "I am LabOS.",
        },
      ],
    },
  ]);

  assert.equal(history.length, 2);
  assert.equal(history[0].role, "user");
  assert.equal(history[1].role, "assistant");
  assert.deepEqual(history[1].content, [{ type: "text", text: "I am LabOS." }]);
});
