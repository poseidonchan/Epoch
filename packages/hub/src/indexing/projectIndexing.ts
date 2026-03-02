import type { DbPool } from "../db/db.js";
import { toIso } from "../utils/time.js";
import { chunkTextForRag, estimateTokenCount, pickTopScoredChunks, type RagChunk, type ScoredRagChunk } from "./chunking.js";
import { embedQueryWithOpenAI, embedTextsWithOpenAI } from "./embeddings.js";
import { ExtractionError, extractFileTextForIndexing } from "./extract.js";
import { fallbackExtractiveSummary, summarizeTextWithOpenAI } from "./summarize.js";

const MAX_EXTRACTED_TEXT_CHARS = 400_000;
const MAX_CHUNK_ROWS_FOR_RETRIEVAL = 2_000;

export type ProjectFileIndexStatus = "processing" | "indexed" | "failed";

export type ProjectFileCatalogItem = {
  path: string;
  modifiedAt: string;
  sizeBytes: number | null;
  indexStatus: ProjectFileIndexStatus | null;
  indexSummary: string | null;
  indexedAt: string | null;
};

export type ProjectFileContextSnippet = {
  path: string;
  chunkIndex: number;
  content: string;
  score: number;
};

export type ProjectFileContextStream = {
  files: ProjectFileCatalogItem[];
  snippets: ProjectFileContextSnippet[];
};

export type IndexUploadInput = {
  projectId: string;
  artifactPath: string;
  uploadId: string;
  storedPath: string;
  contentType: string | null;
};

export type IndexUploadDeps = {
  pool: DbPool;
  getOpenAIApiKey: () => Promise<string | undefined>;
  getOpenAIOcrModel?: () => Promise<string | undefined>;
  onStatusChange?: (status: ProjectFileIndexStatus) => Promise<void> | void;
  syncFileToHpc?: (artifactPath: string, extractedText: string, summary: string) => Promise<void>;
};

export type OcrReindexCandidate = {
  projectId: string;
  artifactPath: string;
  uploadId: string;
  storedPath: string;
  contentType: string | null;
  artifactUpdatedAt: string | null;
};

export async function queueProjectUploadIndexing(input: IndexUploadInput, deps: IndexUploadDeps): Promise<void> {
  const now = new Date().toISOString();
  await deps.pool.query(
    `INSERT INTO project_file_index (
        project_id, artifact_path, upload_id, status, created_at, updated_at
      ) VALUES ($1,$2,$3,'processing',$4,$4)
      ON CONFLICT (project_id, artifact_path) DO UPDATE SET
        upload_id=EXCLUDED.upload_id,
        status='processing',
        error=NULL,
        updated_at=EXCLUDED.updated_at,
        completed_at=NULL`,
    [input.projectId, input.artifactPath, input.uploadId, now]
  );

  void runProjectUploadIndexing(input, deps);
}

export async function runProjectUploadIndexing(input: IndexUploadInput, deps: IndexUploadDeps): Promise<void> {
  const ac = new AbortController();
  const timeout = setTimeout(() => ac.abort(), 120_000);
  timeout.unref?.();
  try {
    void deps.onStatusChange?.("processing")?.catch?.(() => {});

    const apiKey = await deps.getOpenAIApiKey();
    const ocrModel = await deps.getOpenAIOcrModel?.();
    const extraction = await extractFileTextForIndexing(input.storedPath, input.contentType, {
      openAIApiKey: apiKey,
      enablePdfOcrFallback: true,
      ocrModel,
      signal: ac.signal,
    });
    const extractedText = extraction.text.slice(0, MAX_EXTRACTED_TEXT_CHARS);
    const chunks = chunkTextForRag(extractedText);
    if (chunks.length === 0) throw new Error("No chunks were generated for extracted text");

    let embeddingModel: string | null = null;
    let chunkEmbeddings: number[][] = [];

    if (apiKey) {
      try {
        const embeddingsResult = await embedTextsWithOpenAI(chunks, { apiKey, signal: ac.signal });
        if (embeddingsResult.vectors.length !== chunks.length) {
          throw new Error(`Embedding count mismatch: expected ${chunks.length}, got ${embeddingsResult.vectors.length}`);
        }
        embeddingModel = embeddingsResult.model;
        chunkEmbeddings = embeddingsResult.vectors;
      } catch {
        // Keep indexing available without remote embeddings by falling back to
        // lexical-only retrieval (empty vectors).
        chunkEmbeddings = chunks.map(() => []);
      }
    } else {
      // No embedding key configured; still index chunks so lexical retrieval works.
      chunkEmbeddings = chunks.map(() => []);
    }

    let summaryModel: string | null = null;
    let summaryText = fallbackExtractiveSummary(extractedText);
    if (apiKey) {
      try {
        const summaryResult = await summarizeTextWithOpenAI(extractedText, { apiKey, signal: ac.signal });
        summaryModel = summaryResult.model;
        summaryText = summaryResult.summary || summaryText;
      } catch {
        // Keep extractive fallback summary when model summarization fails.
      }
    }

    const indexedAt = new Date().toISOString();
    await deps.pool.query("DELETE FROM project_file_chunk WHERE project_id=$1 AND artifact_path=$2", [input.projectId, input.artifactPath]);

    for (let idx = 0; idx < chunks.length; idx += 1) {
      const content = chunks[idx];
      const embedding = chunkEmbeddings[idx] ?? [];
      await deps.pool.query(
        `INSERT INTO project_file_chunk (
            project_id, artifact_path, chunk_index, content, token_estimate, embedding_json, created_at
         ) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
        [
          input.projectId,
          input.artifactPath,
          idx,
          content,
          estimateTokenCount(content),
          JSON.stringify(embedding),
          indexedAt,
        ]
      );
    }

    const embeddingDim = chunkEmbeddings[0]?.length ?? 0;
    await deps.pool.query(
      `UPDATE project_file_index SET
          status='indexed',
          extractor=$3,
          extracted_text=$4,
          summary=$5,
          summary_model=$6,
          embedding_model=$7,
          embedding_dim=$8,
          chunks_count=$9,
          error=NULL,
          updated_at=$10,
          completed_at=$10
       WHERE project_id=$1 AND artifact_path=$2`,
      [
        input.projectId,
        input.artifactPath,
        extraction.extractor,
        extractedText,
        summaryText,
        summaryModel,
        embeddingModel,
        embeddingDim,
        chunks.length,
        indexedAt,
      ]
    );
    void deps.syncFileToHpc?.(input.artifactPath, extractedText, summaryText)?.catch(() => {});
    void deps.onStatusChange?.("indexed")?.catch?.(() => {});
  } catch (err) {
    const message = normalizeIndexingFailureMessage(err);
    console.error(`[indexing] Failed to index ${input.artifactPath} for project ${input.projectId}: ${message}`);
    await deps.pool.query(
      `UPDATE project_file_index SET
          status='failed',
          error=$3,
          updated_at=$4
       WHERE project_id=$1 AND artifact_path=$2`,
      [input.projectId, input.artifactPath, message, new Date().toISOString()]
    );
    void deps.onStatusChange?.("failed")?.catch?.(() => {});
  } finally {
    clearTimeout(timeout);
  }
}

export function isOcrReindexEligiblePath(pathValue: string): boolean {
  const ext = String(pathValue ?? "").trim().toLowerCase();
  return (
    ext.endsWith(".pdf")
    || ext.endsWith(".png")
    || ext.endsWith(".jpg")
    || ext.endsWith(".jpeg")
    || ext.endsWith(".gif")
    || ext.endsWith(".webp")
    || ext.endsWith(".heic")
    || ext.endsWith(".heif")
  );
}

export function dedupeOcrReindexCandidates(candidates: OcrReindexCandidate[]): OcrReindexCandidate[] {
  const seen = new Set<string>();
  const deduped: OcrReindexCandidate[] = [];
  for (const candidate of candidates) {
    const key = `${candidate.projectId}::${candidate.artifactPath}::${candidate.artifactUpdatedAt ?? ""}`;
    if (seen.has(key)) continue;
    seen.add(key);
    deduped.push(candidate);
  }
  return deduped;
}

export async function listOcrReindexCandidates(pool: DbPool, opts?: { limit?: number }): Promise<OcrReindexCandidate[]> {
  const limit = Math.max(1, Math.min(5_000, Math.floor(opts?.limit ?? 1_000)));
  const rows = await pool.query<any>(
    `SELECT
       a.project_id,
       a.path AS artifact_path,
       a.modified_at AS artifact_updated_at,
       pfi.upload_id,
       u.stored_path,
       u.content_type
     FROM artifacts a
     LEFT JOIN project_file_index pfi
       ON pfi.project_id = a.project_id
      AND pfi.artifact_path = a.path
     LEFT JOIN uploads u
       ON u.id = pfi.upload_id
     WHERE a.origin IN ('user_upload', 'link_upload')
     ORDER BY a.modified_at DESC
     LIMIT $1`,
    [limit]
  );

  return dedupeOcrReindexCandidates(
    rows.rows
      .map((row: any): OcrReindexCandidate | null => {
        const projectId = String(row.project_id ?? "").trim();
        const artifactPath = String(row.artifact_path ?? "").trim();
        const uploadId = String(row.upload_id ?? "").trim();
        const storedPath = String(row.stored_path ?? "").trim();
        if (!projectId || !artifactPath || !uploadId || !storedPath) return null;
        if (!isOcrReindexEligiblePath(artifactPath)) return null;
        return {
          projectId,
          artifactPath,
          uploadId,
          storedPath,
          contentType: typeof row.content_type === "string" ? row.content_type : null,
          artifactUpdatedAt: typeof row.artifact_updated_at === "string" ? row.artifact_updated_at : null,
        };
      })
      .filter((row): row is OcrReindexCandidate => row != null)
  );
}

export async function listProjectFileCatalog(
  pool: DbPool,
  projectId: string,
  opts: { limit: number }
): Promise<ProjectFileCatalogItem[]> {
  const limit = Math.max(1, Math.min(200, Math.floor(opts.limit)));
  const res = await pool.query(
    `SELECT
       a.path,
       a.modified_at,
       a.size_bytes,
       pfi.status AS index_status,
       pfi.summary AS index_summary,
       pfi.completed_at AS indexed_at
     FROM artifacts a
     LEFT JOIN project_file_index pfi
       ON pfi.project_id = a.project_id
      AND pfi.artifact_path = a.path
     WHERE a.project_id=$1
       AND a.origin IN ('user_upload', 'link_upload')
     ORDER BY a.modified_at DESC
     LIMIT $2`,
    [projectId, limit]
  );

  return res.rows
    .map((r: any) => ({
      path: String(r.path ?? ""),
      modifiedAt: toIso(r.modified_at),
      sizeBytes: typeof r.size_bytes === "number" ? r.size_bytes : null,
      indexStatus: normalizeIndexStatus(r.index_status),
      indexSummary: typeof r.index_summary === "string" ? r.index_summary : null,
      indexedAt: typeof r.indexed_at === "string" ? toIso(r.indexed_at) : null,
    }))
    .filter((row) => row.path);
}

export async function buildProjectFileContextStream(
  pool: DbPool,
  projectId: string,
  queryText: string,
  opts: {
    getOpenAIApiKey: () => Promise<string | undefined>;
    fileLimit?: number;
    snippetLimit?: number;
  }
): Promise<ProjectFileContextStream> {
  const files = await listProjectFileCatalog(pool, projectId, { limit: opts.fileLimit ?? 40 });
  const normalizedQuery = String(queryText ?? "").trim();
  if (!normalizedQuery) return { files, snippets: [] };

  const chunks = await loadProjectChunks(pool, projectId, MAX_CHUNK_ROWS_FOR_RETRIEVAL);
  if (chunks.length === 0) return { files, snippets: [] };

  const snippetLimit = Math.max(1, Math.min(12, Math.floor(opts.snippetLimit ?? 6)));

  try {
    const apiKey = await opts.getOpenAIApiKey();
    if (!apiKey) {
      return { files, snippets: lexicalTopChunks(normalizedQuery, chunks, snippetLimit) };
    }
    const queryEmbedding = await embedQueryWithOpenAI(normalizedQuery, { apiKey });
    if (!queryEmbedding) {
      return { files, snippets: lexicalTopChunks(normalizedQuery, chunks, snippetLimit) };
    }
    const top = pickTopScoredChunks(queryEmbedding, chunks, { limit: snippetLimit, minScore: 0.22 });
    if (top.length === 0) {
      return { files, snippets: lexicalTopChunks(normalizedQuery, chunks, snippetLimit) };
    }
    return { files, snippets: top.map(toSnippet) };
  } catch {
    return { files, snippets: lexicalTopChunks(normalizedQuery, chunks, snippetLimit) };
  }
}

export async function getProjectFileIndexRecord(pool: DbPool, projectId: string, artifactPath: string) {
  const res = await pool.query(
    `SELECT status, extractor, extracted_text, summary, summary_model, embedding_model, embedding_dim, chunks_count, error, completed_at
     FROM project_file_index
     WHERE project_id=$1 AND artifact_path=$2`,
    [projectId, artifactPath]
  );
  if (res.rows.length === 0) return null;
  const row: any = res.rows[0];
  return {
    status: normalizeIndexStatus(row.status),
    extractor: typeof row.extractor === "string" ? row.extractor : null,
    extractedText: typeof row.extracted_text === "string" ? row.extracted_text : null,
    summary: typeof row.summary === "string" ? row.summary : null,
    summaryModel: typeof row.summary_model === "string" ? row.summary_model : null,
    embeddingModel: typeof row.embedding_model === "string" ? row.embedding_model : null,
    embeddingDim: typeof row.embedding_dim === "number" ? row.embedding_dim : null,
    chunksCount: typeof row.chunks_count === "number" ? row.chunks_count : 0,
    error: typeof row.error === "string" ? row.error : null,
    completedAt: typeof row.completed_at === "string" ? toIso(row.completed_at) : null,
  };
}

async function loadProjectChunks(pool: DbPool, projectId: string, limit: number): Promise<RagChunk[]> {
  const bounded = Math.max(1, Math.min(20_000, Math.floor(limit)));
  const res = await pool.query(
    `SELECT artifact_path, chunk_index, content, embedding_json
     FROM project_file_chunk
     WHERE project_id=$1
     ORDER BY artifact_path ASC, chunk_index ASC
     LIMIT $2`,
    [projectId, bounded]
  );

  return res.rows
    .map((r: any) => ({
      path: String(r.artifact_path ?? ""),
      chunkIndex: typeof r.chunk_index === "number" ? r.chunk_index : Number(r.chunk_index ?? 0),
      content: String(r.content ?? ""),
      embedding: parseEmbedding(r.embedding_json),
    }))
    .filter((row) => row.path && row.content);
}

function parseEmbedding(value: unknown): number[] | null {
  if (Array.isArray(value)) return value.map((v) => Number(v ?? 0));
  if (typeof value !== "string" || !value.trim()) return null;
  try {
    const parsed = JSON.parse(value);
    if (!Array.isArray(parsed)) return null;
    return parsed.map((v) => Number(v ?? 0));
  } catch {
    return null;
  }
}

function lexicalTopChunks(queryText: string, chunks: RagChunk[], limit: number): ProjectFileContextSnippet[] {
  const terms = tokenize(queryText);
  if (terms.length === 0) return [];

  return chunks
    .map((chunk) => {
      const lowered = chunk.content.toLowerCase();
      let hits = 0;
      for (const term of terms) {
        if (lowered.includes(term)) hits += 1;
      }
      return { ...chunk, score: hits / terms.length };
    })
    .filter((chunk) => chunk.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map(toSnippet);
}

function tokenize(text: string): string[] {
  return String(text ?? "")
    .toLowerCase()
    .split(/[^a-z0-9]+/g)
    .map((t) => t.trim())
    .filter((t) => t.length > 1)
    .slice(0, 24);
}

function normalizeErrorMessage(err: unknown): string {
  const message = err instanceof Error ? err.message : String(err ?? "Unknown indexing error");
  return message.trim().slice(0, 600);
}

function normalizeIndexingFailureMessage(err: unknown): string {
  if (err instanceof ExtractionError) {
    const normalized = normalizeErrorMessage(err);
    if (normalized.startsWith(`${err.code}:`)) {
      return normalized;
    }
    return `${err.code}: ${normalized}`.slice(0, 600);
  }
  return normalizeErrorMessage(err);
}

function normalizeIndexStatus(value: unknown): ProjectFileIndexStatus | null {
  const v = String(value ?? "").trim().toLowerCase();
  if (v === "processing" || v === "indexed" || v === "failed") return v;
  return null;
}

function toSnippet(chunk: ScoredRagChunk): ProjectFileContextSnippet {
  return {
    path: chunk.path,
    chunkIndex: chunk.chunkIndex,
    content: chunk.content,
    score: Number.isFinite(chunk.score) ? chunk.score : 0,
  };
}
