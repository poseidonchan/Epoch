import test from "node:test";
import assert from "node:assert/strict";

import {
  buildPromptImagesFromAttachmentRefs,
  buildSessionAttachmentPromptContext,
  mergeAttachmentRefsWithExistingInline,
  normalizeSessionAttachmentsForChatSend,
  sanitizeArtifactRefsForTransport,
} from "../dist/index.js";

test("normalizeSessionAttachmentsForChatSend extracts prompt images from inline image attachments", () => {
  const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X8r4AAAAASUVORK5CYII=";

  const result = normalizeSessionAttachmentsForChatSend(
    [
      {
        id: "att-1",
        scope: "session",
        name: "photo-1.png",
        path: "session_attachments/s1/photo-1.png",
        mimeType: "image/png",
        inlineDataBase64: pngBase64,
      },
      {
        id: "att-2",
        scope: "session",
        name: "notes.txt",
        path: "session_attachments/s1/notes.txt",
        mimeType: "text/plain",
      },
    ],
    "project-1"
  );

  assert.equal(result.attachmentRefs.length, 2);
  assert.equal(result.attachmentRefs[0].inlineDataBase64, pngBase64);
  assert.equal(result.attachmentRefs[0].byteCount, 68);
  assert.equal(result.promptImages.length, 1);
  assert.deepEqual(result.promptImages[0], {
    type: "image",
    mimeType: "image/png",
    data: pngBase64,
  });
});

test("normalizeSessionAttachmentsForChatSend ignores invalid payloads", () => {
  const result = normalizeSessionAttachmentsForChatSend(
    [
      {
        id: "att-3",
        scope: "session",
        name: "broken.png",
        path: "session_attachments/s1/broken.png",
        mimeType: "image/png",
        inlineDataBase64: "",
      },
      null,
      123,
    ],
    "project-1"
  );

  assert.equal(result.attachmentRefs.length, 1);
  assert.equal(result.promptImages.length, 0);
});

test("mergeAttachmentRefsWithExistingInline restores inline payload for overwrite retries", () => {
  const pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X8r4AAAAASUVORK5CYII=";
  const incoming = normalizeSessionAttachmentsForChatSend(
    [
      {
        id: "att-restore",
        scope: "session",
        name: "photo-restore.png",
        path: "session_attachments/s1/photo-restore.png",
        mimeType: "image/png",
      },
    ],
    "project-1"
  ).attachmentRefs;
  const existing = [
    {
      displayText: "photo-restore.png",
      projectID: "project-1",
      path: "session_attachments/s1/photo-restore.png",
      artifactID: "att-restore",
      scope: "session",
      mimeType: "image/png",
      sourceName: "photo-restore.png",
      inlineDataBase64: pngBase64,
      byteCount: 68,
    },
  ];

  const merged = mergeAttachmentRefsWithExistingInline(incoming, existing);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].inlineDataBase64, pngBase64);
  assert.equal(merged[0].byteCount, 68);

  const promptImages = buildPromptImagesFromAttachmentRefs(merged);
  assert.equal(promptImages.length, 1);
  assert.equal(promptImages[0].mimeType, "image/png");
});

test("sanitizeArtifactRefsForTransport strips inline payloads", () => {
  const refs = [
    {
      displayText: "photo.png",
      projectID: "project-1",
      path: "session_attachments/s1/photo.png",
      inlineDataBase64: "ZmFrZS1pbWFnZS1kYXRh",
      byteCount: 16,
    },
  ];
  const sanitized = sanitizeArtifactRefsForTransport(refs);
  assert.equal(sanitized.length, 1);
  assert.equal(sanitized[0].inlineDataBase64, undefined);
  assert.equal(sanitized[0].byteCount, 16);
});

function makePdfBase64(text) {
  const escaped = String(text ?? "")
    .replace(/\\/g, "\\\\")
    .replace(/\(/g, "\\(")
    .replace(/\)/g, "\\)");
  const stream = `BT\n/F1 18 Tf\n72 100 Td\n(${escaped}) Tj\nET`;
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
    `4 0 obj\n<< /Length ${Buffer.byteLength(stream, "utf8")} >>\nstream\n${stream}\nendstream\nendobj\n`,
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
  ];

  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  for (const object of objects) {
    offsets.push(Buffer.byteLength(pdf, "utf8"));
    pdf += object;
  }
  const xrefOffset = Buffer.byteLength(pdf, "utf8");
  pdf += "xref\n0 6\n0000000000 65535 f \n";
  for (let i = 1; i <= 5; i += 1) {
    pdf += `${String(offsets[i]).padStart(10, "0")} 00000 n \n`;
  }
  pdf += `trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;
  return Buffer.from(pdf, "utf8").toString("base64");
}

test("buildSessionAttachmentPromptContext extracts inline text and PDF content for session attachments", async () => {
  const normalized = normalizeSessionAttachmentsForChatSend(
    [
      {
        id: "att-txt",
        scope: "session",
        name: "notes.txt",
        path: "session_attachments/s1/notes.txt",
        mimeType: "text/plain",
        inlineDataBase64: Buffer.from("This is plain text from a session attachment.", "utf8").toString("base64"),
      },
      {
        id: "att-pdf",
        scope: "session",
        name: "paper.pdf",
        path: "session_attachments/s1/paper.pdf",
        mimeType: "application/pdf",
        inlineDataBase64: makePdfBase64("PDF session attachment extraction works."),
      },
    ],
    "project-1"
  );

  const context = await buildSessionAttachmentPromptContext(normalized.attachmentRefs);
  assert.match(context, /notes\.txt/i);
  assert.match(context, /plain text from a session attachment/i);
  assert.match(context, /paper\.pdf/i);
  assert.match(context, /pdf session attachment/i);
});
