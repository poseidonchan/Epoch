import path from "node:path";
import { readFile } from "node:fs/promises";

import { PDFParse } from "pdf-parse";

export type ExtractionResult = {
  text: string;
  extractor: "pdf-parse" | "openai-pdf-ocr" | "utf8";
};

export type ExtractionOptions = {
  openAIApiKey?: string | null;
  enablePdfOcrFallback?: boolean;
  ocrModel?: string | null;
  signal?: AbortSignal;
};

const TEXT_EXTENSIONS = new Set([
  ".txt",
  ".md",
  ".markdown",
  ".csv",
  ".tsv",
  ".json",
  ".xml",
  ".html",
  ".htm",
  ".yaml",
  ".yml",
  ".py",
  ".js",
  ".ts",
  ".tsx",
  ".jsx",
  ".sql",
  ".log",
]);
const OPENAI_BASE_URL = (process.env.LABOS_OPENAI_BASE_URL?.trim() || "https://api.openai.com").replace(/\/+$/, "");
const DEFAULT_PDF_OCR_MODEL = "gpt-5.2";
const PDF_OCR_MAX_BYTES = parsePositiveInt(process.env.LABOS_PDF_OCR_MAX_BYTES, 15 * 1024 * 1024);
const PDF_OCR_MIN_TEXT_LENGTH = parsePositiveInt(process.env.LABOS_PDF_OCR_MIN_TEXT_LENGTH, 240);
const PDF_OCR_MAX_RETRIES = parsePositiveInt(process.env.LABOS_PDF_OCR_MAX_RETRIES, 2);

type OpenAIResponsesOutputContent = {
  type?: string | null;
  text?: string | null;
};

type OpenAIResponsesOutputItem = {
  content?: OpenAIResponsesOutputContent[] | null;
};

type OpenAIResponsesResponse = {
  output_text?: string | null;
  output?: OpenAIResponsesOutputItem[] | null;
};

export async function extractFileTextForIndexing(
  filePath: string,
  contentType?: string | null,
  opts?: ExtractionOptions
): Promise<ExtractionResult> {
  const ext = path.extname(filePath).toLowerCase();
  if (isPdf(ext, contentType)) {
    const raw = await readFile(filePath);
    return await extractPdfTextWithFallback(raw, {
      fileName: path.basename(filePath),
      openAIApiKey: opts?.openAIApiKey,
      enablePdfOcrFallback: opts?.enablePdfOcrFallback ?? true,
      ocrModel: opts?.ocrModel,
      signal: opts?.signal,
    });
  }

  if (!isLikelyTextFile(ext, contentType)) {
    throw new Error(`Unsupported file type for indexing: ${(contentType ?? ext) || "unknown"}`);
  }

  const raw = await readFile(filePath, "utf8");
  const text = normalizeExtractedText(raw);
  if (!text) throw new Error("No extractable text found in file");
  return { text, extractor: "utf8" };
}

export async function extractInlineAttachmentTextForPrompt(input: {
  fileName: string;
  contentType?: string | null;
  data: Buffer;
}, opts?: ExtractionOptions): Promise<ExtractionResult> {
  const name = String(input.fileName ?? "").trim();
  const ext = path.extname(name).toLowerCase();
  if (isPdf(ext, input.contentType)) {
    return await extractPdfTextWithFallback(input.data, {
      fileName: name,
      openAIApiKey: opts?.openAIApiKey,
      enablePdfOcrFallback: opts?.enablePdfOcrFallback ?? false,
      ocrModel: opts?.ocrModel,
      signal: opts?.signal,
    });
  }

  if (!isLikelyTextFile(ext, input.contentType)) {
    throw new Error(`Unsupported attachment type for inline extraction: ${(input.contentType ?? ext) || "unknown"}`);
  }

  const text = normalizeExtractedText(input.data.toString("utf8"));
  if (!text) throw new Error("No extractable text found in attachment");
  return { text, extractor: "utf8" };
}

function isPdf(ext: string, contentType?: string | null): boolean {
  if (ext === ".pdf") return true;
  const normalized = (contentType ?? "").toLowerCase().trim();
  return normalized === "application/pdf";
}

function isLikelyTextFile(ext: string, contentType?: string | null): boolean {
  if (TEXT_EXTENSIONS.has(ext)) return true;

  const normalized = (contentType ?? "").toLowerCase().trim();
  if (!normalized) return false;
  if (normalized.startsWith("text/")) return true;
  if (normalized.includes("json")) return true;
  if (normalized.includes("xml")) return true;
  if (normalized.includes("csv")) return true;
  if (normalized.includes("yaml")) return true;
  return false;
}

function normalizeExtractedText(input: string): string {
  return String(input ?? "")
    .replace(/\u0000/g, "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export async function extractPdfBufferText(raw: Buffer): Promise<string> {
  return extractPdfText(raw);
}

async function extractPdfText(raw: Buffer): Promise<string> {
  const parser = new PDFParse({ data: raw });
  try {
    const result = await parser.getText();
    return normalizeExtractedText(result?.text ?? "");
  } finally {
    await parser.destroy().catch(() => {
      // ignore parser cleanup failures
    });
  }
}

async function extractPdfTextWithFallback(
  raw: Buffer,
  opts: {
    fileName?: string;
    openAIApiKey?: string | null;
    enablePdfOcrFallback?: boolean;
    ocrModel?: string | null;
    signal?: AbortSignal;
  }
): Promise<ExtractionResult> {
  let parsedText = "";
  let parsedError: unknown;
  try {
    parsedText = await extractPdfText(raw);
  } catch (err) {
    parsedError = err;
  }

  const shouldTryFallback = shouldAttemptPdfOcrFallback(parsedText);
  const openAIApiKey = String(opts.openAIApiKey ?? "").trim();
  const canTryFallback = Boolean(opts.enablePdfOcrFallback) && Boolean(openAIApiKey);

  if (shouldTryFallback && canTryFallback) {
    try {
      const ocrText = await extractPdfTextWithOpenAIOcr(raw, {
        apiKey: openAIApiKey,
        fileName: opts.fileName,
        ocrModel: opts.ocrModel,
        signal: opts.signal,
      });
      if (ocrText) {
        return { text: ocrText, extractor: "openai-pdf-ocr" };
      }
    } catch (err) {
      if (parsedText) {
        return { text: parsedText, extractor: "pdf-parse" };
      }
      const message = normalizeErrorMessage(err);
      if (message) {
        throw new Error(`No extractable text found in PDF: OCR failed (${message})`);
      }
    }
  }

  if (parsedText) {
    return { text: parsedText, extractor: "pdf-parse" };
  }

  const parserMessage = normalizeErrorMessage(parsedError);
  if (parserMessage) {
    throw new Error(`No extractable text found in PDF (${parserMessage})`);
  }
  throw new Error("No extractable text found in PDF");
}

function shouldAttemptPdfOcrFallback(text: string): boolean {
  const normalized = normalizeExtractedText(text);
  if (!normalized) return true;
  if (normalized.length < PDF_OCR_MIN_TEXT_LENGTH) return true;

  const alnumCount = (normalized.match(/[A-Za-z0-9]/g) || []).length;
  if (alnumCount === 0) return true;
  const ratio = alnumCount / normalized.length;
  if (ratio < 0.18) return true;

  return false;
}

async function extractPdfTextWithOpenAIOcr(
  raw: Buffer,
  opts: { apiKey: string; fileName?: string; ocrModel?: string | null; signal?: AbortSignal }
): Promise<string> {
  if (!raw.length) return "";
  if (raw.length > PDF_OCR_MAX_BYTES) {
    throw new Error(`PDF too large for OCR (${raw.length} bytes)`);
  }

  const dataUrl = `data:application/pdf;base64,${raw.toString("base64")}`;
  const fileName = normalizePdfFileName(opts.fileName);

  const response = await withRetries(async () => {
    const res = await fetch(`${OPENAI_BASE_URL}/v1/responses`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${opts.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: resolvePdfOcrModel(opts.ocrModel),
        temperature: 0,
        input: [
          {
            role: "user",
            content: [
              {
                type: "input_text",
                text:
                  "Extract all readable text from this PDF. Return plain text only, keep reading order, and avoid summaries.",
              },
              {
                type: "input_file",
                filename: fileName,
                file_data: dataUrl,
              },
            ],
          },
        ],
      }),
      signal: opts.signal,
    });

    if (!res.ok) {
      const message = await safeReadText(res);
      throw new Error(`OpenAI OCR failed (${res.status}): ${message}`);
    }
    return (await res.json()) as OpenAIResponsesResponse;
  });

  const outputText = extractResponseText(response);
  return normalizeExtractedText(outputText);
}

function resolvePdfOcrModel(configModel?: string | null): string {
  const configured = normalizeOptionalString(configModel);
  if (configured) return configured;
  const envModel = normalizeOptionalString(process.env.LABOS_PDF_OCR_MODEL);
  if (envModel) return envModel;
  return DEFAULT_PDF_OCR_MODEL;
}

function extractResponseText(response: OpenAIResponsesResponse): string {
  if (typeof response.output_text === "string" && response.output_text.trim()) {
    return response.output_text;
  }

  const parts: string[] = [];
  for (const output of response.output ?? []) {
    const content = Array.isArray(output?.content) ? output.content : [];
    for (const item of content) {
      const type = String(item?.type ?? "").toLowerCase();
      if ((type === "output_text" || type === "text") && typeof item?.text === "string") {
        const text = item.text.trim();
        if (text) parts.push(text);
      }
    }
  }
  return parts.join("\n");
}

function normalizePdfFileName(fileName?: string): string {
  const normalized = String(fileName ?? "").trim().replace(/[^a-zA-Z0-9._-]+/g, "_");
  if (!normalized) return "document.pdf";
  if (normalized.toLowerCase().endsWith(".pdf")) return normalized;
  return `${normalized}.pdf`;
}

async function withRetries<T>(fn: () => Promise<T>): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= PDF_OCR_MAX_RETRIES; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt >= PDF_OCR_MAX_RETRIES) break;
      await sleep(300 * attempt);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error("OCR request failed");
}

async function safeReadText(res: Response): Promise<string> {
  try {
    const text = await res.text();
    return text.slice(0, 600);
  } catch {
    return "unknown error";
  }
}

function normalizeErrorMessage(err: unknown): string {
  if (!err) return "";
  const message = err instanceof Error ? err.message : String(err);
  return message.trim().slice(0, 300);
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  const value = Number.parseInt(String(raw ?? "").trim(), 10);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return value;
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}
