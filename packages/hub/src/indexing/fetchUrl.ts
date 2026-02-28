import { extractPdfBufferText } from "./extract.js";

const MAX_TEXT_CHARS = 400_000;
const FETCH_TIMEOUT_MS = 30_000;

export type FetchedContent = {
  url: string;
  resolvedUrl: string;
  title: string;
  contentType: string;
  textContent: string;
  byteLength: number;
};

export async function fetchUrlContent(url: string, opts?: { signal?: AbortSignal }): Promise<FetchedContent> {
  const parsed = new URL(url);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error(`Unsupported URL protocol: ${parsed.protocol}`);
  }

  // arXiv: convert abstract page to PDF URL
  const arxivId = extractArxivId(url);
  if (arxivId) {
    return await fetchArxivPdf(arxivId, url, opts);
  }

  const ac = new AbortController();
  const timeout = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
  timeout.unref?.();

  // Compose signals: respect both caller signal and our timeout
  if (opts?.signal) {
    opts.signal.addEventListener("abort", () => ac.abort(), { once: true });
  }

  try {
    const res = await fetch(url, {
      signal: ac.signal,
      redirect: "follow",
      headers: { "User-Agent": "LabOS-Hub/1.0" },
    });

    if (!res.ok) {
      throw new Error(`HTTP ${res.status} fetching ${url}`);
    }

    const resolvedUrl = res.url || url;
    const ct = (res.headers.get("content-type") ?? "").toLowerCase();

    // PDF response
    if (ct.includes("application/pdf")) {
      const buffer = Buffer.from(await res.arrayBuffer());
      const text = await extractPdfBufferText(buffer);
      return {
        url,
        resolvedUrl,
        title: titleFromUrl(resolvedUrl),
        contentType: "application/pdf",
        textContent: text.slice(0, MAX_TEXT_CHARS),
        byteLength: buffer.length,
      };
    }

    // HTML or text response
    const html = await res.text();
    const byteLength = Buffer.byteLength(html, "utf8");

    if (ct.includes("text/html") || ct.includes("application/xhtml")) {
      const title = extractHtmlTitle(html) || titleFromUrl(resolvedUrl);
      const textContent = stripHtmlTags(html).slice(0, MAX_TEXT_CHARS);
      return { url, resolvedUrl, title, contentType: "text/html", textContent, byteLength };
    }

    // Plain text / other text types
    return {
      url,
      resolvedUrl,
      title: titleFromUrl(resolvedUrl),
      contentType: ct || "text/plain",
      textContent: html.slice(0, MAX_TEXT_CHARS),
      byteLength,
    };
  } finally {
    clearTimeout(timeout);
  }
}

function extractArxivId(url: string): string | null {
  // Match arxiv.org/abs/<id> or arxiv.org/pdf/<id>
  const match = url.match(/arxiv\.org\/(?:abs|pdf)\/([0-9]+\.[0-9]+(?:v[0-9]+)?)/);
  return match ? match[1] : null;
}

async function fetchArxivPdf(arxivId: string, originalUrl: string, opts?: { signal?: AbortSignal }): Promise<FetchedContent> {
  const pdfUrl = `https://export.arxiv.org/pdf/${arxivId}`;
  const ac = new AbortController();
  const timeout = setTimeout(() => ac.abort(), FETCH_TIMEOUT_MS);
  timeout.unref?.();

  if (opts?.signal) {
    opts.signal.addEventListener("abort", () => ac.abort(), { once: true });
  }

  try {
    const res = await fetch(pdfUrl, {
      signal: ac.signal,
      redirect: "follow",
      headers: { "User-Agent": "LabOS-Hub/1.0" },
    });

    if (!res.ok) {
      throw new Error(`HTTP ${res.status} fetching arXiv PDF for ${arxivId}`);
    }

    const buffer = Buffer.from(await res.arrayBuffer());
    const text = await extractPdfBufferText(buffer);
    return {
      url: originalUrl,
      resolvedUrl: pdfUrl,
      title: `arXiv:${arxivId}`,
      contentType: "application/pdf",
      textContent: text.slice(0, MAX_TEXT_CHARS),
      byteLength: buffer.length,
    };
  } finally {
    clearTimeout(timeout);
  }
}

function extractHtmlTitle(html: string): string {
  const match = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  if (!match) return "";
  return match[1].replace(/\s+/g, " ").trim().slice(0, 300);
}

function stripHtmlTags(html: string): string {
  // Remove script and style blocks
  let text = html.replace(/<script[\s\S]*?<\/script>/gi, "");
  text = text.replace(/<style[\s\S]*?<\/style>/gi, "");
  // Remove all HTML tags
  text = text.replace(/<[^>]+>/g, " ");
  // Decode common entities
  text = text.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&nbsp;/g, " ");
  // Normalize whitespace
  text = text.replace(/[ \t]+/g, " ").replace(/\n\s*\n/g, "\n\n").trim();
  return text;
}

function titleFromUrl(url: string): string {
  try {
    const parsed = new URL(url);
    const pathPart = parsed.pathname.split("/").filter(Boolean).pop() ?? "";
    return decodeURIComponent(pathPart || parsed.hostname).slice(0, 200);
  } catch {
    return url.slice(0, 200);
  }
}
