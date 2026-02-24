import test from "node:test";
import assert from "node:assert/strict";

import { chunkTextForRag, cosineSimilarity, pickTopScoredChunks } from "../dist/index.js";

test("chunkTextForRag creates bounded overlapping chunks", () => {
  const text = "abcdefghijklmnopqrstuvwxyz".repeat(120);
  const chunks = chunkTextForRag(text, { chunkSize: 400, overlap: 80 });

  assert.ok(chunks.length > 3);
  assert.ok(chunks.every((c) => c.length <= 400));

  for (let i = 1; i < chunks.length; i += 1) {
    const prevTail = chunks[i - 1].slice(-40);
    assert.ok(chunks[i].includes(prevTail.slice(0, 20)));
  }
});

test("cosineSimilarity returns 1 for identical vectors and -1 for opposite vectors", () => {
  assert.equal(cosineSimilarity([1, 2, 3], [1, 2, 3]).toFixed(6), "1.000000");
  assert.equal(cosineSimilarity([1, 0], [-1, 0]).toFixed(6), "-1.000000");
});

test("pickTopScoredChunks returns highest scoring chunks first", () => {
  const query = [1, 0, 0];
  const chunks = [
    { path: "uploads/a.txt", chunkIndex: 0, content: "A", embedding: [0.2, 0.7, 0.1] },
    { path: "uploads/b.txt", chunkIndex: 2, content: "B", embedding: [0.9, 0.05, 0.05] },
    { path: "uploads/c.txt", chunkIndex: 1, content: "C", embedding: [0.6, 0.3, 0.1] },
  ];

  const top = pickTopScoredChunks(query, chunks, { limit: 2 });

  assert.equal(top.length, 2);
  assert.equal(top[0].path, "uploads/b.txt");
  assert.equal(top[1].path, "uploads/c.txt");
  assert.ok(top[0].score >= top[1].score);
});
