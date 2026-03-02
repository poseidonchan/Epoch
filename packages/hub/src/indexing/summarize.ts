const DEFAULT_SUMMARY_MODEL = process.env.EPOCH_INDEX_SUMMARY_MODEL?.trim() || "gpt-4o-mini";
const OPENAI_BASE_URL = (process.env.EPOCH_OPENAI_BASE_URL?.trim() || "https://api.openai.com").replace(/\/+$/, "");

type OpenAIChatCompletionResponse = {
  choices?: Array<{ message?: { content?: string | null } }>;
};

export async function summarizeTextWithOpenAI(
  text: string,
  opts: { apiKey: string; model?: string; signal?: AbortSignal }
): Promise<{ model: string; summary: string }> {
  const normalized = String(text ?? "").trim();
  const model = opts.model ?? DEFAULT_SUMMARY_MODEL;
  if (!normalized) return { model, summary: "" };

  const excerpt = normalized.slice(0, 24_000);
  const summary = await withRetries(async () => {
    const res = await fetch(`${OPENAI_BASE_URL}/v1/chat/completions`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${opts.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model,
        temperature: 0.1,
        max_tokens: 220,
        messages: [
          {
            role: "system",
            content:
              "Summarize the document for retrieval context. Return 4-6 concise bullets covering purpose, key facts, and useful terms.",
          },
          {
            role: "user",
            content: excerpt,
          },
        ],
      }),
      signal: opts.signal,
    });

    if (!res.ok) {
      const message = await safeReadText(res);
      throw new Error(`OpenAI summary failed (${res.status}): ${message}`);
    }

    const body = (await res.json()) as OpenAIChatCompletionResponse;
    const content = String(body?.choices?.[0]?.message?.content ?? "").trim();
    return content;
  });

  return { model, summary: summary || fallbackExtractiveSummary(excerpt) };
}

export async function generateSessionTitle(
  messages: Array<{ role: string; text: string }>,
  opts: { apiKey?: string; model?: string }
): Promise<string | null> {
  if (messages.length === 0) return null;

  const normalizedMessages = messages
    .map((entry) => ({
      role: String(entry.role ?? "").trim(),
      text: String(entry.text ?? "").replace(/\s+/g, " ").trim(),
    }))
    .filter((entry) => entry.text.length > 0);
  if (normalizedMessages.length === 0) return null;

  const fallback = generateSessionTitleFallback(normalizedMessages);
  if (!opts.apiKey) {
    return fallback;
  }

  const model = opts.model ?? DEFAULT_SUMMARY_MODEL;
  const transcript = normalizedMessages
    .slice(0, 10)
    .map((m) => `${m.role}: ${m.text}`)
    .join("\n")
    .slice(0, 8_000);

  try {
    const modelTitle = await withRetries(async () => {
      const res = await fetch(`${OPENAI_BASE_URL}/v1/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          temperature: 0.2,
          max_tokens: 40,
          messages: [
            {
              role: "system",
              content:
                "Generate one concise conversation title (3-8 words). Match the main language used by the user. Return title text only.",
            },
            { role: "user", content: transcript },
          ],
        }),
      });

      if (!res.ok) {
        const message = await safeReadText(res);
        throw new Error(`OpenAI title generation failed (${res.status}): ${message}`);
      }

      const body = (await res.json()) as OpenAIChatCompletionResponse;
      return String(body?.choices?.[0]?.message?.content ?? "");
    });

    return sanitizeSessionTitle(modelTitle) ?? fallback;
  } catch {
    return fallback;
  }
}

export function fallbackExtractiveSummary(text: string): string {
  const lines = String(text ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);

  if (lines.length === 0) return "";

  const bullets = lines.slice(0, 5).map((line) => {
    const clipped = line.length > 180 ? `${line.slice(0, 177)}...` : line;
    return `- ${clipped}`;
  });

  return bullets.join("\n");
}

async function withRetries<T>(fn: () => Promise<T>): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt >= 2) break;
      await sleep(300 * attempt);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error("Summary request failed");
}

async function safeReadText(res: Response): Promise<string> {
  try {
    const text = await res.text();
    return text.slice(0, 600);
  } catch {
    return "unknown error";
  }
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function generateSessionTitleFallback(messages: Array<{ role: string; text: string }>): string | null {
  const preferred =
    messages.find((entry) => entry.role.toLowerCase() === "user" && entry.text.length > 0)?.text
    ?? messages.find((entry) => entry.text.length > 0)?.text
    ?? "";
  if (!preferred) return null;

  const compact = preferred
    .replace(/[`*_#>\[\]\(\)]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!compact) return null;

  if (containsCJK(compact)) {
    return sanitizeSessionTitle(compact.slice(0, 18));
  }

  const words = compact.split(/\s+/).filter(Boolean);
  const filler = new Set([
    "please",
    "help",
    "can",
    "could",
    "would",
    "should",
    "need",
    "i",
    "we",
    "you",
    "to",
    "a",
    "an",
    "the",
    "my",
    "our",
  ]);
  while (words.length > 0 && filler.has(words[0].toLowerCase())) {
    words.shift();
  }
  const candidate = (words.length > 0 ? words : compact.split(/\s+/).filter(Boolean)).slice(0, 8).join(" ");
  return sanitizeSessionTitle(candidate);
}

function sanitizeSessionTitle(raw: string): string | null {
  let title = String(raw ?? "")
    .replace(/\r?\n+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!title) return null;

  title = title.replace(/^(?:title|session title|subject|标题)\s*[:：-]\s*/i, "");
  title = title.replace(/^["'“”‘’`]+/, "").replace(/["'“”‘’`]+$/, "").trim();
  title = title.replace(/[.。!！?？;；,:：]+$/g, "").trim();
  if (!title) return null;

  if (containsCJK(title)) {
    if (title.length > 24) {
      title = title.slice(0, 24).trim();
    }
  } else {
    const words = title.split(/\s+/).filter(Boolean);
    if (words.length > 8) {
      title = words.slice(0, 8).join(" ");
    }
    if (title.length > 72) {
      title = title.slice(0, 72).trim();
    }
  }

  return title || null;
}

function containsCJK(text: string): boolean {
  return /[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/.test(text);
}
