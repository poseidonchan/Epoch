import test from "node:test";
import assert from "node:assert/strict";

import { appendAttachmentSummaryToText } from "../dist/index.js";

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
