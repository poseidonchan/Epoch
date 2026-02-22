# File Upload and Context Ingestion Design

Date: 2026-02-22
Status: Approved for planning
Owner: LabOS

## Objective

Implement two distinct upload behaviors while fixing model-context visibility:

1. Project page uploads are project-scoped and indexed for retrieval.
2. Session composer `+` attachments are session-only and persisted in session history.
3. The model must reliably see project file metadata and use on-demand retrieval for file content.

## Required Product Behavior

1. Project page `Upload Files` remains a project-wide file store.
2. Session composer `+` behaves like ChatGPT:
   - bottom sheet entry point for photos/files,
   - camera and recent-photo lane,
   - explicit `Add Files` action for document picker.
3. Selected composer items appear above the input text box as pending attachment chips:
   - image thumbnails for photos,
   - icon + filename badges for files.
4. Composer attachments are session-only, persisted in that session history, and excluded from project file indexing.
5. Project uploaded files are indexed (metadata + description + chunk embeddings), and content is fetched on demand.

## Constraints and Compatibility

1. Preserve existing external contracts:
   - WS frame shape (`req/res/event`),
   - handshake (`connect.challenge` -> `connect`),
   - existing method/event names,
   - existing upload/artifact HTTP routes.
2. Preserve invariants:
   - deleting session detaches runs and keeps artifacts,
   - deleting project deletes all project rows/files,
   - user-upload vs generated separation stays origin-based.

## Current Gaps (Confirmed)

1. iOS upload flow currently stores filename stubs only and does not upload file bytes.
2. Hub run-context assembly includes bootstrap + transcript but does not include project file catalog or retrieval path.

## Reference Pattern Extracted from Open Notebook

The following patterns are adopted from the Open Notebook implementation:

1. Extract -> chunk -> embed pipeline for uploaded content.
2. Content-type-aware chunking with bounded chunk size and overlap.
3. Batched embedding requests and retry-safe processing.
4. Retrieval separation:
   - metadata/context shown by default,
   - full content loaded only when queried.
5. Hybrid retrieval model:
   - vector similarity primary,
   - text search fallback.

## Architecture Decision

Chosen approach: hybrid in-hub indexing.

1. Project files:
   - real multipart upload,
   - async extraction/chunk/embedding,
   - searchable catalog + chunk index.
2. Session attachments:
   - session-scoped persisted attachments tied to message/session history,
   - no embedding/indexing.
3. Agent turn context:
   - always inject project file catalog (metadata + short description + indexed status),
   - file content provided via explicit retrieval/read calls.

## Data Model Changes

### Hub database (additive)

1. `project_file_index`
   - `id`, `project_id`, `artifact_path`,
   - `title`, `mime_type`, `size_bytes`,
   - `description`,
   - `extracted_text` (optional cached),
   - `embedding_model`, `embedding_dim`,
   - `status` (`pending|ready|failed`), `error`,
   - `updated_at`, `extracted_at`.
2. `project_file_chunk`
   - `id`, `project_id`, `artifact_path`,
   - `chunk_index`, `content`, `token_estimate`,
   - `embedding_json`,
   - `created_at`.
3. `session_attachment`
   - `id`, `project_id`, `session_id`,
   - `message_id` (nullable until send),
   - `local_name`, `stored_path`, `mime_type`, `size_bytes`,
   - optional media dimensions,
   - `created_at`.

### Indexes

1. `project_file_index(project_id, artifact_path)` unique.
2. `project_file_chunk(project_id, artifact_path, chunk_index)` unique.
3. `project_file_chunk(project_id)` lookup index.
4. `session_attachment(session_id, created_at)` lookup index.

## Contract Extensions (Additive, Non-Breaking)

1. Extend `chat.send` params with optional `attachments` payload.
2. Add retrieval RPC methods:
   - `project.files.search`,
   - `project.files.read`,
   - optional `project.files.reindex`.
3. Keep all existing methods/events/endpoints unchanged.

## UI/UX Design

### Project page

1. Existing `Project Files` sheet remains the project-wide management surface.
2. `Add Photos` and `Add Files` in this sheet perform real upload to Hub.
3. Uploaded results appear in project file list and become retrievable/indexable.

### Session composer

1. `+` opens a chat attachment bottom sheet.
2. Sheet includes:
   - camera action,
   - recent photo preview row,
   - explicit `Add Files` button.
3. Selected items are staged in composer as pending chips above input.
4. Send action:
   - sends text + attachment refs,
   - persists session attachments in history,
   - clears staged chips.

### Message timeline

1. Session attachment refs render inline with messages.
2. Tapping a ref opens preview (image/file view).
3. Session-only refs remain within the session and do not pollute project file catalog.

## Backend Processing Flow

### Project uploads

1. Receive multipart bytes at existing upload endpoint.
2. Persist upload row and artifact row (`origin=user_upload`).
3. Enqueue indexing task:
   - read content,
   - extract text,
   - generate short description,
   - chunk,
   - embed chunks,
   - upsert index + chunk rows.
4. Mark status (`ready` or `failed`) with error details.

### Retrieval

1. `project.files.search`:
   - hybrid ranking (vector + text fallback),
   - grouped/snippet response by file/chunk.
2. `project.files.read`:
   - return targeted file/chunk content only.

### Agent context

1. `buildRunContext` includes `projectFilesCatalog`.
2. Prompt/tool instructions direct the model to:
   - inspect metadata/description first,
   - call retrieval/read for detailed content.
3. Session attachments for the current conversation are available as explicit refs without indexing.

## Testing Strategy

### Hub tests

1. Upload endpoint stores bytes and creates artifact correctly.
2. Indexing pipeline creates catalog/chunks and status transitions.
3. Retrieval returns expected matches/snippets.
4. Run context includes project file catalog and excludes full text by default.
5. Existing invariants continue to pass.

### iOS tests

1. Project upload uses real network upload path.
2. Session attachment lifecycle:
   - stage,
   - send,
   - persist in session history,
   - clear composer state.
3. Session attachments do not appear in project uploaded list.

### Manual QA

1. Project upload and session attachment paths behave distinctly.
2. Model can answer questions using project files through retrieval.
3. Composer previews and badge interactions match expected UX.

## Rollout Plan

1. PR-A: iOS real multipart upload plumbing for project files.
2. PR-B: session-only attachment UI/state/history persistence.
3. PR-C: hub indexing schema + pipeline.
4. PR-D: retrieval RPC + run-context integration + prompt/tool updates.
5. PR-E: tests, performance tuning, cleanup.

## Risks and Mitigations

1. Large-file embedding cost:
   - mitigate with chunk limits, file-size caps, and retry/backoff.
2. Prompt bloat from catalog:
   - include concise metadata/description only.
3. UX confusion between project vs session attachment scopes:
   - explicit labels and separate entry flows.
4. Regression risk in chat send path:
   - preserve existing `chat.send` behavior when `attachments` absent.

## Final Decision Record

1. Composer `+` attachments are session-only and persisted in session history.
2. Embedding/indexing is project-files only.
3. Project context exposure is metadata + small description always, content on demand via retrieval.
