const DEFAULT_EMBEDDING_MODEL = process.env.LABOS_INDEX_EMBED_MODEL?.trim() || "text-embedding-3-small";
const OPENAI_BASE_URL = (process.env.LABOS_OPENAI_BASE_URL?.trim() || "https://api.openai.com").replace(/\/+$/, "");
const EMBEDDING_BATCH_SIZE = 32;
const EMBEDDING_MAX_RETRIES = 3;

type OpenAIEmbeddingResponse = {
  data: Array<{ embedding: number[]; index: number }>;
};

export async function embedTextsWithOpenAI(
  texts: string[],
  opts: { apiKey: string; model?: string; signal?: AbortSignal }
): Promise<{ model: string; vectors: number[][] }> {
  const normalized = texts.map((t) => String(t ?? "").trim()).filter(Boolean);
  if (normalized.length === 0) return { model: opts.model ?? DEFAULT_EMBEDDING_MODEL, vectors: [] };

  const model = opts.model ?? DEFAULT_EMBEDDING_MODEL;
  const vectors: number[][] = [];

  for (let i = 0; i < normalized.length; i += EMBEDDING_BATCH_SIZE) {
    const batch = normalized.slice(i, i + EMBEDDING_BATCH_SIZE);
    const response = await withRetries(async () => {
      const res = await fetch(`${OPENAI_BASE_URL}/v1/embeddings`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${opts.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          input: batch,
        }),
        signal: opts.signal,
      });

      if (!res.ok) {
        const message = await safeReadText(res);
        throw new Error(`OpenAI embeddings failed (${res.status}): ${message}`);
      }

      return (await res.json()) as OpenAIEmbeddingResponse;
    });

    const sorted = [...(response.data ?? [])].sort((a, b) => a.index - b.index);
    for (const item of sorted) {
      vectors.push(Array.isArray(item.embedding) ? item.embedding.map(Number) : []);
    }
  }

  return { model, vectors };
}

export async function embedQueryWithOpenAI(
  query: string,
  opts: { apiKey: string; model?: string; signal?: AbortSignal }
): Promise<number[] | null> {
  const normalized = String(query ?? "").trim();
  if (!normalized) return null;
  const { vectors } = await embedTextsWithOpenAI([normalized], opts);
  return vectors[0] ?? null;
}

async function withRetries<T>(fn: () => Promise<T>): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= EMBEDDING_MAX_RETRIES; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt >= EMBEDDING_MAX_RETRIES) break;
      await sleep(300 * attempt);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error("Embedding request failed");
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
