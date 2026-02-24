import path from "node:path";
import { readFile } from "node:fs/promises";

import { PDFParse } from "pdf-parse";

export type ExtractionResult = {
  text: string;
  extractor: "pdf-parse" | "utf8";
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

export async function extractFileTextForIndexing(
  filePath: string,
  contentType?: string | null
): Promise<ExtractionResult> {
  const ext = path.extname(filePath).toLowerCase();
  if (isPdf(ext, contentType)) {
    const raw = await readFile(filePath);
    const text = await extractPdfText(raw);
    if (!text) throw new Error("No extractable text found in PDF");
    return { text, extractor: "pdf-parse" };
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
}): Promise<ExtractionResult> {
  const name = String(input.fileName ?? "").trim();
  const ext = path.extname(name).toLowerCase();
  if (isPdf(ext, input.contentType)) {
    const text = await extractPdfText(input.data);
    if (!text) throw new Error("No extractable text found in PDF attachment");
    return { text, extractor: "pdf-parse" };
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
