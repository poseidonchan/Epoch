import test from "node:test";
import assert from "node:assert/strict";

import {
  dedupeOcrReindexCandidates,
  isOcrReindexEligiblePath,
} from "../dist/index.js";

test("isOcrReindexEligiblePath matches PDF and image uploads", () => {
  assert.equal(isOcrReindexEligiblePath("uploads/paper.pdf"), true);
  assert.equal(isOcrReindexEligiblePath("uploads/scan.PNG"), true);
  assert.equal(isOcrReindexEligiblePath("uploads/photo.heic"), true);
  assert.equal(isOcrReindexEligiblePath("uploads/archive.zip"), false);
  assert.equal(isOcrReindexEligiblePath("links/page.txt"), false);
});

test("dedupeOcrReindexCandidates keeps one row per project/path/updatedAt", () => {
  const rows = [
    {
      projectId: "p1",
      artifactPath: "uploads/a.pdf",
      uploadId: "u1",
      storedPath: "/tmp/a.pdf",
      contentType: "application/pdf",
      artifactUpdatedAt: "2026-03-01T21:00:00.000Z",
    },
    {
      projectId: "p1",
      artifactPath: "uploads/a.pdf",
      uploadId: "u1",
      storedPath: "/tmp/a.pdf",
      contentType: "application/pdf",
      artifactUpdatedAt: "2026-03-01T21:00:00.000Z",
    },
    {
      projectId: "p1",
      artifactPath: "uploads/a.pdf",
      uploadId: "u2",
      storedPath: "/tmp/a-v2.pdf",
      contentType: "application/pdf",
      artifactUpdatedAt: "2026-03-01T21:10:00.000Z",
    },
  ];

  const deduped = dedupeOcrReindexCandidates(rows);
  assert.equal(deduped.length, 2);
  assert.equal(deduped[0].uploadId, "u1");
  assert.equal(deduped[1].uploadId, "u2");
});
