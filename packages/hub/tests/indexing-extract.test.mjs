import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, rm, writeFile } from "node:fs/promises";

import { extractFileTextForIndexing } from "../dist/index.js";

function makeSimplePdfBuffer(text) {
  const escaped = String(text ?? "")
    .replaceAll("\\", "\\\\")
    .replaceAll("(", "\\(")
    .replaceAll(")", "\\)");
  const stream = `BT\n/F1 18 Tf\n72 72 Td\n(${escaped}) Tj\nET`;
  const objects = [
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n",
    "4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    `5 0 obj\n<< /Length ${Buffer.byteLength(stream, "utf8")} >>\nstream\n${stream}\nendstream\nendobj\n`,
  ];

  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  for (const object of objects) {
    offsets.push(Buffer.byteLength(pdf, "utf8"));
    pdf += object;
  }

  const xrefStart = Buffer.byteLength(pdf, "utf8");
  pdf += "xref\n0 6\n";
  pdf += "0000000000 65535 f \n";
  for (let index = 1; index <= 5; index += 1) {
    const offset = String(offsets[index]).padStart(10, "0");
    pdf += `${offset} 00000 n \n`;
  }
  pdf += "trailer\n<< /Root 1 0 R /Size 6 >>\n";
  pdf += `startxref\n${xrefStart}\n%%EOF\n`;
  return Buffer.from(pdf, "utf8");
}

function parseFetchJsonBody(init) {
  const raw = init?.body;
  if (typeof raw !== "string") return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

test("extractFileTextForIndexing falls back to OpenAI OCR when pdf-parse has no text", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "scan.pdf");
  await writeFile(pdfPath, Buffer.from("not-a-valid-pdf"));

  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response(
      JSON.stringify({
        output_text: "Scanned PDF text from OCR fallback.",
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  };

  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  const result = await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
  });

  assert.equal(result.extractor, "openai-pdf-ocr");
  assert.equal(result.text, "Scanned PDF text from OCR fallback.");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url.endsWith("/v1/responses"), true);
});

test("extractFileTextForIndexing prefers OCR for parseable PDFs when key exists", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-priority-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "typed.pdf");
  await writeFile(pdfPath, makeSimplePdfBuffer("Parser fallback content"));

  const originalFetch = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), init });
    return new Response(JSON.stringify({ output_text: "OCR preferred content with readable alphanumeric text 12345." }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  const result = await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
  });

  assert.equal(result.extractor, "openai-pdf-ocr");
  assert.equal(result.text, "OCR preferred content with readable alphanumeric text 12345.");
  assert.equal(calls.length, 1);
});

test("extractFileTextForIndexing falls back to pdf-parse when OCR fails and parsed text quality is good", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-fallback-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "typed.pdf");
  const denseText = Array.from({ length: 12 }, () => "Readable OCR fallback paragraph with alpha numeric content 12345.").join(" ");
  await writeFile(pdfPath, makeSimplePdfBuffer(denseText));

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ error: "upstream error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });

  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  const result = await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
  });

  assert.equal(result.extractor, "pdf-parse");
  assert.match(result.text, /Readable OCR fallback/);
});

test("extractFileTextForIndexing does not fall back when OCR succeeds with low-quality text", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-low-quality-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "typed.pdf");
  const parserFriendlyText = Array.from({ length: 10 }, () => "Readable parser text with alpha numeric content 12345.").join(" ");
  await writeFile(pdfPath, makeSimplePdfBuffer(parserFriendlyText));

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ output_text: "%%%% #### ----" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  await assert.rejects(
    () =>
      extractFileTextForIndexing(pdfPath, "application/pdf", {
        openAIApiKey: "sk-test",
        enablePdfOcrFallback: true,
      }),
    /OCR_FAILED/
  );
});

test("extractFileTextForIndexing requires OCR key for low-quality PDF text", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-low-quality-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "scan.pdf");
  await writeFile(pdfPath, makeSimplePdfBuffer("%%%% #### ----"));

  await assert.rejects(
    () =>
      extractFileTextForIndexing(pdfPath, "application/pdf", {
        enablePdfOcrFallback: true,
      }),
    /PDF_OCR_REQUIRES_KEY/
  );
});

test("extractFileTextForIndexing performs image OCR when key exists", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-image-ocr-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pngPath = path.join(tmpDir, "note.png");
  const tinyPngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII=";
  await writeFile(pngPath, Buffer.from(tinyPngBase64, "base64"));

  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ output_text: "Image OCR extracted text" }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });

  t.after(() => {
    globalThis.fetch = originalFetch;
  });

  const result = await extractFileTextForIndexing(pngPath, "image/png", {
    openAIApiKey: "sk-test",
  });

  assert.equal(result.extractor, "openai-image-ocr");
  assert.equal(result.text, "Image OCR extracted text");
});

test("extractFileTextForIndexing requires OCR key for images", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-image-no-key-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pngPath = path.join(tmpDir, "scan.png");
  const tinyPngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5GZfQAAAAASUVORK5CYII=";
  await writeFile(pngPath, Buffer.from(tinyPngBase64, "base64"));

  await assert.rejects(
    () => extractFileTextForIndexing(pngPath, "image/png"),
    /IMAGE_OCR_REQUIRES_KEY/
  );
});

test("extractFileTextForIndexing rejects unsupported PDF content when OCR fallback is unavailable", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-no-ocr-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "scan.pdf");
  await writeFile(pdfPath, Buffer.from("not-a-valid-pdf"));

  await assert.rejects(
    () =>
      extractFileTextForIndexing(pdfPath, "application/pdf", {
        enablePdfOcrFallback: true,
      }),
    /No extractable text found in PDF/
  );
});

test("extractFileTextForIndexing keeps text extraction for plain text files", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-text-extract-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const textPath = path.join(tmpDir, "note.txt");
  await writeFile(textPath, "hello\nworld");

  const result = await extractFileTextForIndexing(textPath, "text/plain");
  assert.equal(result.extractor, "utf8");
  assert.equal(result.text, "hello\nworld");
});

test("extractFileTextForIndexing uses configured OCR model over env model", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-model-config-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "scan.pdf");
  await writeFile(pdfPath, Buffer.from("not-a-valid-pdf"));

  const originalFetch = globalThis.fetch;
  const originalEnvModel = process.env.EPOCH_PDF_OCR_MODEL;
  const models = [];
  process.env.EPOCH_PDF_OCR_MODEL = "env-model-ocr";

  globalThis.fetch = async (_url, init) => {
    const body = parseFetchJsonBody(init);
    models.push(String(body?.model ?? ""));
    return new Response(JSON.stringify({ output_text: "OCR model override test output with readable alphanumeric content 12345." }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };

  t.after(() => {
    globalThis.fetch = originalFetch;
    if (originalEnvModel == null) {
      delete process.env.EPOCH_PDF_OCR_MODEL;
    } else {
      process.env.EPOCH_PDF_OCR_MODEL = originalEnvModel;
    }
  });

  const result = await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
    ocrModel: "configured-ocr-model",
  });

  assert.equal(result.extractor, "openai-pdf-ocr");
  assert.equal(models.length, 1);
  assert.equal(models[0], "configured-ocr-model");
});

test("extractFileTextForIndexing falls back to env/default OCR model when config model is absent", async (t) => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "hub-pdf-ocr-model-fallback-"));
  t.after(async () => {
    await rm(tmpDir, { recursive: true, force: true });
  });

  const pdfPath = path.join(tmpDir, "scan.pdf");
  await writeFile(pdfPath, Buffer.from("not-a-valid-pdf"));

  const originalFetch = globalThis.fetch;
  const originalEnvModel = process.env.EPOCH_PDF_OCR_MODEL;
  const models = [];
  let invocation = 0;

  globalThis.fetch = async (_url, init) => {
    const body = parseFetchJsonBody(init);
    models.push(String(body?.model ?? ""));
    return new Response(
      JSON.stringify({
        output_text: `OCR model fallback output ${invocation++} with readable alphanumeric content 12345.`,
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  };

  process.env.EPOCH_PDF_OCR_MODEL = "env-model-ocr";
  await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
  });

  delete process.env.EPOCH_PDF_OCR_MODEL;
  await extractFileTextForIndexing(pdfPath, "application/pdf", {
    openAIApiKey: "sk-test",
    enablePdfOcrFallback: true,
  });

  t.after(() => {
    globalThis.fetch = originalFetch;
    if (originalEnvModel == null) {
      delete process.env.EPOCH_PDF_OCR_MODEL;
    } else {
      process.env.EPOCH_PDF_OCR_MODEL = originalEnvModel;
    }
  });

  assert.equal(models.length, 2);
  assert.equal(models[0], "env-model-ocr");
  assert.equal(models[1], "gpt-5.2");
});
