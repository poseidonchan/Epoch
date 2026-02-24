import test from "node:test";
import assert from "node:assert/strict";

import { rewriteSessionMessagesForOverwrite } from "../dist/index.js";

test("rewriteSessionMessagesForOverwrite updates target user message and trims trailing branch", () => {
  const rows = [
    {
      id: "user-1",
      ts: "2026-02-22T10:00:00.000Z",
      role: "user",
      content: "Old question",
      artifact_refs: "[]",
      proposed_plan: null,
      run_id: null,
      parent_id: null,
    },
    {
      id: "assistant-1",
      ts: "2026-02-22T10:00:01.000Z",
      role: "assistant",
      content: "Old answer",
      artifact_refs: "[]",
      proposed_plan: null,
      run_id: null,
      parent_id: null,
    },
  ];

  const result = rewriteSessionMessagesForOverwrite(rows, {
    messageId: "user-1",
    text: "New question",
    artifactRefs: [{ displayText: "photo.jpg", mimeType: "image/jpeg" }],
  });

  assert.equal(result.ok, true);
  assert.equal(result.updatedMessage?.id, "user-1");
  assert.equal(result.updatedMessage?.text, "New question");
  assert.deepEqual(result.deletedMessageIds, ["assistant-1"]);
  assert.equal(result.keptRows.length, 1);
});

test("rewriteSessionMessagesForOverwrite rejects non-user overwrite target", () => {
  const rows = [
    {
      id: "assistant-1",
      ts: "2026-02-22T10:00:01.000Z",
      role: "assistant",
      content: "Response",
      artifact_refs: "[]",
      proposed_plan: null,
      run_id: null,
      parent_id: null,
    },
  ];

  const result = rewriteSessionMessagesForOverwrite(rows, {
    messageId: "assistant-1",
    text: "No-op",
    artifactRefs: [],
  });

  assert.equal(result.ok, false);
  assert.equal(result.reason, "target_not_user");
});
