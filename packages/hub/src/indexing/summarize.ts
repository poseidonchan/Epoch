const DEFAULT_SUMMARY_MODEL = process.env.LABOS_INDEX_SUMMARY_MODEL?.trim() || "gpt-4o-mini";
const OPENAI_BASE_URL = (process.env.LABOS_OPENAI_BASE_URL?.trim() || "https://api.openai.com").replace(/\/+$/, "");

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
  opts: { apiKey: string; model?: string }
): Promise<string | null> {
  if (!opts.apiKey || messages.length === 0) return null;

  const model = opts.model ?? DEFAULT_SUMMARY_MODEL;
  const transcript = messages
    .slice(0, 10)
    .map((m) => `${m.role}: ${m.text}`)
    .join("\n")
    .slice(0, 8_000);

  try {
    const title = await withRetries(async () => {
      const res = await fetch(`${OPENAI_BASE_URL}/v1/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          temperature: 0.3,
          max_tokens: 40,
          messages: [
            {
              role: "system",
              content:
                "Given this conversation, generate a concise title (3-8 words). Return only the title, no quotes.",
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
      return String(body?.choices?.[0]?.message?.content ?? "").trim();
    });

    return title || null;
  } catch {
    return null;
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
