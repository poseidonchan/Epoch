export type RagChunk = {
  path: string;
  chunkIndex: number;
  content: string;
  embedding: number[] | null;
};

export type ScoredRagChunk = RagChunk & { score: number };

const DEFAULT_CHUNK_SIZE = 1200;
const DEFAULT_OVERLAP = 180;

export function chunkTextForRag(
  text: string,
  opts?: {
    chunkSize?: number;
    overlap?: number;
  }
): string[] {
  const normalized = typeof text === "string" ? text.trim() : "";
  if (!normalized) return [];

  const chunkSize = Math.max(200, Math.floor(opts?.chunkSize ?? DEFAULT_CHUNK_SIZE));
  const overlap = Math.max(0, Math.min(chunkSize - 1, Math.floor(opts?.overlap ?? DEFAULT_OVERLAP)));
  if (normalized.length <= chunkSize) return [normalized];

  const chunks: string[] = [];
  let start = 0;
  while (start < normalized.length) {
    const maxEnd = Math.min(normalized.length, start + chunkSize);
    let end = maxEnd;

    if (maxEnd < normalized.length) {
      const preferredBreak = findChunkBoundary(normalized, start, maxEnd);
      if (preferredBreak > start + 100) end = preferredBreak;
    }

    const chunk = normalized.slice(start, end).trim();
    if (chunk) chunks.push(chunk);
    if (end >= normalized.length) break;

    start = Math.max(start + 1, end - overlap);
  }

  return chunks;
}

function findChunkBoundary(text: string, start: number, maxEnd: number): number {
  const windowStart = Math.max(start, maxEnd - 200);
  for (let i = maxEnd; i > windowStart; i -= 1) {
    const c = text[i];
    if (c === "\n") return i;
    if (c === "." || c === "!" || c === "?") return i + 1;
    if (c === " ") return i;
  }
  return maxEnd;
}

export function estimateTokenCount(text: string): number {
  const normalized = typeof text === "string" ? text : "";
  if (!normalized) return 0;
  const bytes = Buffer.byteLength(normalized, "utf8");
  return bytes > 0 ? Math.ceil(bytes / 4) : 0;
}

export function cosineSimilarity(a: number[], b: number[]): number {
  if (!Array.isArray(a) || !Array.isArray(b) || a.length === 0 || b.length === 0) return 0;
  const len = Math.min(a.length, b.length);
  if (len === 0) return 0;

  let dot = 0;
  let aNorm = 0;
  let bNorm = 0;
  for (let i = 0; i < len; i += 1) {
    const av = Number(a[i] ?? 0);
    const bv = Number(b[i] ?? 0);
    dot += av * bv;
    aNorm += av * av;
    bNorm += bv * bv;
  }
  if (aNorm === 0 || bNorm === 0) return 0;
  return dot / Math.sqrt(aNorm * bNorm);
}

export function pickTopScoredChunks(
  queryEmbedding: number[],
  chunks: RagChunk[],
  opts?: {
    limit?: number;
    minScore?: number;
  }
): ScoredRagChunk[] {
  const limit = Math.max(1, Math.floor(opts?.limit ?? 6));
  const minScore = typeof opts?.minScore === "number" ? opts!.minScore : 0.2;

  return chunks
    .filter((chunk) => Array.isArray(chunk.embedding) && chunk.embedding.length > 0)
    .map((chunk) => {
      const score = cosineSimilarity(queryEmbedding, chunk.embedding ?? []);
      return { ...chunk, score };
    })
    .filter((chunk) => chunk.score >= minScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit);
}
