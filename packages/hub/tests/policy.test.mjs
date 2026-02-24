import test from "node:test";
import assert from "node:assert/strict";

import { appendAttachmentSummaryToText, hasExecutionIntent, shouldEnableExecutionTools } from "../dist/index.js";

test("hasExecutionIntent detects explicit execution verbs", () => {
  assert.equal(hasExecutionIntent("Please run this experiment"), true);
  assert.equal(hasExecutionIntent("Can you analyze this data?"), true);
  assert.equal(hasExecutionIntent("What's this?"), false);
});

test("shouldEnableExecutionTools enables tools only for plan mode or execution intent", () => {
  assert.equal(shouldEnableExecutionTools({ planMode: false, userText: "What's this?" }), false);
  assert.equal(shouldEnableExecutionTools({ planMode: true, userText: "What's this?" }), true);
  assert.equal(shouldEnableExecutionTools({ planMode: false, userText: "download the file" }), false);
});

test("shouldEnableExecutionTools ignores attachment-derived text unless plan mode is enabled", () => {
  const promptText = [
    "What's this paper about?",
    "",
    "[Session attachment extracted content]",
    "Use the following extracted text from user-attached files when answering:",
    "",
    "This paper analyzes build systems and execution pipelines in detail.",
  ].join("\n");

  assert.equal(shouldEnableExecutionTools({ planMode: false, userText: promptText }), false);
  assert.equal(shouldEnableExecutionTools({ planMode: true, userText: promptText }), true);
});

test("appendAttachmentSummaryToText lists session attachments", () => {
  const output = appendAttachmentSummaryToText("What's this?", [
    { displayText: "photo-1.jpg", mimeType: "image/jpeg" },
  ]);

  assert.match(output, /\[Session attachments\]/i);
  assert.match(output, /photo-1\.jpg \(image\/jpeg\)/);
});

test("appendAttachmentSummaryToText is a no-op without attachments", () => {
  const input = "Hello";
  assert.equal(appendAttachmentSummaryToText(input, []), input);
});
