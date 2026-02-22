# Session Attachments and Project File Indexing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship message-only session attachments plus project-only file indexing/retrieval so the model can reliably use uploaded project files without changing existing external contracts.

**Architecture:** Keep current transport and endpoint contracts stable, add additive protocol fields/methods, and split behavior by scope. Session attachments are persisted to session history only; project uploads flow through existing upload endpoints and are indexed (metadata + description + chunk embeddings). Agent run context gets a compact project file catalog and fetches full content on demand.

**Tech Stack:** Swift 6, SwiftUI, XCTest, TypeScript (Node 22), Fastify, better-sqlite3 migrations, OpenAI embeddings API, pnpm workspace.

---

## Execution Rules

1. Use `@superpowers/test-driven-development` for each task (write failing test first).
2. Use `@superpowers/systematic-debugging` if any test fails unexpectedly.
3. Use `@superpowers/verification-before-completion` before claiming milestone completion.
4. Keep commits small and scoped to each task.
5. Preserve all current contracts/invariants from the approved design doc.

---

### Task 1: Add Additive Protocol Surface

**Files:**
- Modify: `packages/protocol/src/schema.ts`
- Modify: `packages/protocol/src/gateway.ts`
- Modify: `packages/protocol/tests/schema.test.mjs`
- Modify: `packages/protocol/tests/gateway.test.mjs`

**Step 1: Write the failing test**

Add protocol tests for:
- optional `chat.send.params.attachments`,
- new operator methods `project.files.search` and `project.files.read`.

```js
test("chat.send supports optional attachments", () => { /* assert schema path exists */ });
test("gateway registry includes project file retrieval methods", () => { /* assert list contains both */ });
```

**Step 2: Run test to verify it fails**

Run: `pnpm -C packages/protocol test`
Expected: FAIL because schema/methods are missing.

**Step 3: Write minimal implementation**

Add:

```ts
const ChatSendAttachment = Type.Object({
  id: Type.String(),
  scope: Type.Union([Type.Literal("session"), Type.Literal("project")]),
  name: Type.String(),
  path: Type.String(),
  mimeType: Type.Optional(Type.String()),
});
```

Extend `chat.send` params with optional `attachments: Type.Array(ChatSendAttachment)`.
Append method names to `operatorMethods`.

**Step 4: Run test to verify it passes**

Run: `pnpm -C packages/protocol test`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/protocol/src/schema.ts packages/protocol/src/gateway.ts \
  packages/protocol/tests/schema.test.mjs packages/protocol/tests/gateway.test.mjs
git commit -m "feat(protocol): add chat attachments and project file retrieval methods"
```

---

### Task 2: Regenerate Protocol Artifacts and Swift Contract

**Files:**
- Regenerate: `packages/protocol/dist/schema.json`
- Regenerate: `packages/protocol/dist/gateway.json`
- Regenerate: `Sources/LabOSCore/Generated/GatewayContract.swift`
- Modify: `Tests/LabOSCoreTests/AppStoreSettingsTests.swift`

**Step 1: Write the failing test**

Add a Swift test that references the new generated methods:

```swift
func testGatewayContractContainsProjectFileMethods() {
    XCTAssertNotNil(GatewayMethod(rawValue: "project.files.search"))
    XCTAssertNotNil(GatewayMethod(rawValue: "project.files.read"))
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreSettingsTests/testGatewayContractContainsProjectFileMethods`
Expected: FAIL before regeneration.

**Step 3: Write minimal implementation**

Run:

```bash
pnpm -C packages/protocol build
pnpm protocol:gen:swift
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreSettingsTests/testGatewayContractContainsProjectFileMethods`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/protocol/dist/schema.json packages/protocol/dist/gateway.json \
  Sources/LabOSCore/Generated/GatewayContract.swift \
  Tests/LabOSCoreTests/AppStoreSettingsTests.swift
git commit -m "chore(protocol): regenerate schema and Swift gateway contract"
```

---

### Task 3: Add Core Attachment Types and Scope Tests

**Files:**
- Modify: `Sources/LabOSCore/Models.swift`
- Create: `Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift`

**Step 1: Write the failing test**

Create tests:
- `testSessionAttachmentsStayOutOfProjectUploads`
- `testPendingAttachmentsClearAfterSuccessfulSend`
- `testSessionAttachmentsPersistInMessageHistory`

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreAttachmentsTests`
Expected: FAIL (types/APIs missing).

**Step 3: Write minimal implementation**

Add model types:

```swift
public enum AttachmentScope: String, Codable, Sendable { case session, project }
public struct ComposerAttachment: Identifiable, Hashable, Codable, Sendable { ... }
```

Extend chat artifact metadata with optional scope/mime.

**Step 4: Run test to verify partial progress**

Run: `swift test --filter AppStoreAttachmentsTests`
Expected: compile errors resolved; behavior tests still FAIL.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/Models.swift Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift
git commit -m "test(core): add attachment scope tests and model primitives"
```

---

### Task 4: Implement Real Project Multipart Upload Path

**Files:**
- Create: `Sources/LabOSCore/HubUploadClient.swift`
- Modify: `Sources/LabOSCore/AppStore.swift`
- Modify: `Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift`

**Step 1: Write the failing test**

Add:
- `testProjectUploadUsesMultipartEndpoint`
- `testProjectUploadFailureDoesNotCreateFakeArtifact`

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreAttachmentsTests/testProjectUploadUsesMultipartEndpoint`
Expected: FAIL (current code uses local filename stubs).

**Step 3: Write minimal implementation**

Introduce upload client abstraction and wire AppStore project upload to:
- `POST /projects/:projectId/uploads`,
- use multipart bytes,
- refresh artifacts from hub response/events.

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreAttachmentsTests`
Expected: PASS for project upload tests.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/HubUploadClient.swift Sources/LabOSCore/AppStore.swift \
  Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift
git commit -m "feat(core): implement real project multipart uploads"
```

---

### Task 5: Implement Session Attachment Staging + Send Persistence

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Modify: `Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift`

**Step 1: Write the failing test**

Add:
- `testSendPersistsSessionAttachmentsIntoUserMessageRefs`
- `testEditingBadgeCancelClearsComposerTextAndAttachments`

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreAttachmentsTests/testSendPersistsSessionAttachmentsIntoUserMessageRefs`
Expected: FAIL.

**Step 3: Write minimal implementation**

Add state:

```swift
@Published private(set) var pendingComposerAttachmentsBySession: [UUID: [ComposerAttachment]] = [:]
```

On send/overwrite:
- serialize staged attachments as user message refs,
- clear staged attachments after send,
- preserve message-only scope.

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreAttachmentsTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift
git commit -m "feat(core): persist session-only attachments in chat history"
```

---

### Task 6: Build Session Composer Attachment UI (ChatGPT-like)

**Files:**
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift`
- Modify: `Sources/LabOSApp/Views/Session/SessionChatView.swift`
- Modify: `Sources/LabOSApp/Views/Session/MessageBubbleView.swift`

**Step 1: Write the failing UI test/build check**

Add at least one view-model/state test in `AppStoreAttachmentsTests`:
- pending chips are visible when staged,
- chips are removed when user deletes one or sends.

**Step 2: Run test/build to verify it fails**

Run:

```bash
swift test --filter AppStoreAttachmentsTests
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: FAIL or missing behavior.

**Step 3: Write minimal implementation**

Implement in session chat flow:
- `+` opens session attachment sheet (camera/recent row/Add Files),
- selected items render above composer input as chips,
- sent user bubbles render attachment refs.

**Step 4: Run test/build to verify it passes**

Run same commands.
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/InlineComposerView.swift \
  Sources/LabOSApp/Views/Session/SessionChatView.swift \
  Sources/LabOSApp/Views/Session/MessageBubbleView.swift \
  Tests/LabOSCoreTests/AppStoreAttachmentsTests.swift
git commit -m "feat(app): add session composer attachment sheet and chips"
```

---

### Task 7: Keep Project Page Upload Flow Separate

**Files:**
- Modify: `Sources/LabOSApp/Views/Project/ProjectPageView.swift`
- Modify: `Tests/LabOSCoreTests/HubIntegrationTests.swift`

**Step 1: Write the failing test**

Add test assertion:
- project-page upload still lands in project uploaded artifacts list,
- session attachments do not.

**Step 2: Run test to verify it fails**

Run: `swift test --filter HubIntegrationTests`
Expected: FAIL before separation is complete.

**Step 3: Write minimal implementation**

Ensure project page actions call project-upload path only.
Do not reuse session staging store for project uploads.

**Step 4: Run test to verify it passes**

Run: `swift test --filter HubIntegrationTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Project/ProjectPageView.swift Tests/LabOSCoreTests/HubIntegrationTests.swift
git commit -m "fix(app): enforce project upload vs session attachment separation"
```

---

### Task 8: Add Hub DB Migration for Project Index + Session Attachments

**Files:**
- Create: `packages/hub/migrations/0003_project_file_indexing.sql`
- Create: `packages/hub/tests/uploads-indexing-schema.test.mjs`

**Step 1: Write the failing test**

Add test to assert tables/indexes:
- `project_file_index`,
- `project_file_chunk`,
- `session_attachment`.

**Step 2: Run test to verify it fails**

Run: `pnpm -C packages/hub test`
Expected: FAIL (migration/tables missing).

**Step 3: Write minimal implementation**

Create migration with additive tables and indexes only.

**Step 4: Run test to verify it passes**

Run: `pnpm -C packages/hub test`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/hub/migrations/0003_project_file_indexing.sql \
  packages/hub/tests/uploads-indexing-schema.test.mjs
git commit -m "feat(hub): add schema for project index and session attachments"
```

---

### Task 9: Implement Project Indexing Pipeline (Extract, Describe, Chunk, Embed)

**Files:**
- Create: `packages/hub/src/indexing/chunking.ts`
- Create: `packages/hub/src/indexing/extract.ts`
- Create: `packages/hub/src/indexing/embeddings.ts`
- Create: `packages/hub/src/indexing/projectIndexing.ts`
- Modify: `packages/hub/src/server.ts`
- Create: `packages/hub/tests/uploads-indexing-pipeline.test.mjs`

**Step 1: Write the failing test**

Add tests:
- text upload produces index row + chunks + `ready` status,
- embedding failure marks `failed` but upload endpoint still succeeds.

**Step 2: Run test to verify it fails**

Run: `pnpm -C packages/hub test`
Expected: FAIL on missing indexing behavior.

**Step 3: Write minimal implementation**

Implement:
- upload-triggered async indexing job,
- bounded chunking with overlap,
- batched embedding calls,
- status transitions `pending -> ready|failed`.

**Step 4: Run test to verify it passes**

Run: `pnpm -C packages/hub test`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/hub/src/indexing/chunking.ts packages/hub/src/indexing/extract.ts \
  packages/hub/src/indexing/embeddings.ts packages/hub/src/indexing/projectIndexing.ts \
  packages/hub/src/server.ts packages/hub/tests/uploads-indexing-pipeline.test.mjs
git commit -m "feat(hub): index project uploads into searchable chunks"
```

---

### Task 10: Add Retrieval Methods and Agent Context Catalog

**Files:**
- Modify: `packages/hub/src/server.ts`
- Modify: `packages/hub/src/agent/runtime.ts`
- Create: `packages/hub/tests/project-files-retrieval.test.mjs`
- Create: `packages/hub/tests/run-context-project-files.test.mjs`

**Step 1: Write the failing test**

Add tests:
- `project.files.search` returns ranked results/snippets,
- `project.files.read` returns requested content slice,
- `buildRunContext` includes metadata+description catalog only (no full text dump).

**Step 2: Run test to verify it fails**

Run: `pnpm -C packages/hub test`
Expected: FAIL.

**Step 3: Write minimal implementation**

Implement `project.files.search` and `project.files.read` RPC handlers.
Inject catalog into run context and prompt instructions for on-demand retrieval.

**Step 4: Run test to verify it passes**

Run: `pnpm -C packages/hub test`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/hub/src/server.ts packages/hub/src/agent/runtime.ts \
  packages/hub/tests/project-files-retrieval.test.mjs \
  packages/hub/tests/run-context-project-files.test.mjs
git commit -m "feat(hub): add project file retrieval and catalog context injection"
```

---

### Task 11: Persist Session Attachments in Hub Chat Path

**Files:**
- Modify: `packages/hub/src/server.ts`
- Create: `packages/hub/tests/chat-session-attachments.test.mjs`

**Step 1: Write the failing test**

Add tests:
- `chat.send` with session attachments stores them in message refs/history,
- session attachments do not create `user_upload` artifacts and are excluded from indexing.

**Step 2: Run test to verify it fails**

Run: `pnpm -C packages/hub test`
Expected: FAIL.

**Step 3: Write minimal implementation**

Extend `chat.send` parser for optional attachments and persist scope-aware refs.
Write `session_attachment` rows keyed by project/session/message.

**Step 4: Run test to verify it passes**

Run: `pnpm -C packages/hub test`
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/hub/src/server.ts packages/hub/tests/chat-session-attachments.test.mjs
git commit -m "feat(hub): persist message-scoped session attachments"
```

---

### Task 12: End-to-End Verification and Regression Guardrails

**Files:**
- Modify: `Tests/LabOSCoreTests/AppStoreSemanticsTests.swift`
- Modify: `Tests/LabOSCoreTests/HubIntegrationTests.swift`
- Create: `packages/hub/tests/invariants.test.mjs` (if not present)
- Modify: `docs/plans/2026-02-22-file-upload-and-context-design.md` (mark implemented details)

**Step 1: Write the failing tests**

Add coverage for:
- session delete keeps artifacts and detaches runs,
- project delete wipes everything,
- cancel plan creates no run,
- uploaded vs generated separation by origin,
- session attachments not indexed.

**Step 2: Run full suites to verify failing baseline**

Run:

```bash
pnpm -w test
swift test
```

Expected: FAIL until final integration fixes are done.

**Step 3: Write minimal implementation fixes**

Fix integration mismatches only (no refactors):
- optional decoding safety,
- old-client compatibility (attachments absent),
- invariant regressions.

**Step 4: Run full verification**

Run:

```bash
pnpm -w test
swift test
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSCoreTests/AppStoreSemanticsTests.swift \
  Tests/LabOSCoreTests/HubIntegrationTests.swift \
  packages/hub/tests/invariants.test.mjs \
  docs/plans/2026-02-22-file-upload-and-context-design.md
git commit -m "test: verify session attachments and project indexing end to end"
```

---

## Manual QA Checklist (Must Pass Before Merge)

1. Project page upload:
   - upload image + document,
   - both appear in project files list.
2. Session `+` flow:
   - add photos and files,
   - chips appear above composer text,
   - send clears chips.
3. Scope correctness:
   - session attachments visible in session message history,
   - session attachments not present in project files list/index.
4. Model visibility:
   - ask about a project-uploaded file,
   - model references file catalog and can fetch content on demand.
5. Regression checks:
   - no white-screen-on-send,
   - no forced auto-scroll while reading older messages.
