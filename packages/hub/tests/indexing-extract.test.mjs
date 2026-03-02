import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { mkdtemp, rm, writeFile } from "node:fs/promises";

import { extractFileTextForIndexing } from "../dist/index.js";

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
    return new Response(JSON.stringify({ output_text: "ocr text" }), {
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
    return new Response(JSON.stringify({ output_text: `ocr text ${invocation++}` }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
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
