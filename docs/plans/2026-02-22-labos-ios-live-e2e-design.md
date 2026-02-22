# LabOS iOS Live E2E Test Design

## Status
- Date: 2026-02-22
- Design state: approved
- Scope owner: LabOS iOS app + live Hub backend

## Problem Statement
Manual end-to-end testing is currently the bottleneck for LabOS iOS development. Regressions are escaping small fixes, especially around message lifecycle, attachment behavior, indexing flows, and cross-page UI state.

The target is a rigorous, human-like E2E test suite that validates real app interactions against a live Hub, including UI behavior, backend state, filesystem state, and screenshot evidence.

## Goals
1. Replace repeated manual validation with automated E2E coverage for critical user workflows.
2. Make tests strict enough to block regressions immediately.
3. Keep tests live-model/live-Hub (no deterministic model stubs for primary gate).
4. Capture screenshots and structured execution artifacts at every major step.
5. Validate both UI and backend invariants (including on-disk project deletion).

## Non-Goals
1. Replace all existing unit/integration tests.
2. Add HPC execution coverage in this phase (settings persistence is in scope, compute flow is not).
3. Add deterministic response mocks for mainline E2E gating.

## Chosen Strategy
Primary gate: full live-model E2E against live Hub via iOS UI automation.

Why chosen:
- Highest fidelity with real user behavior.
- Directly targets current pain points where manual checks are required.
- Stronger protection against regressions that only appear with full stack state.

Trade-offs:
- Higher runtime and flakiness risk than mocked tests.
- Requires robust waiting, semantic assertions, and artifact capture.

## Requirements Matrix
1. Home settings must support save/connect/disconnect Hub and save HPC settings.
2. Project create/delete must enforce unique project storage and recursive physical deletion.
3. Project-page composer send creates sessions; project-file badge is the only project upload control; composer plus is session attachment only.
4. Text messages must receive assistant responses.
5. Photo message flow must show thumbnail preview before send and produce grounded response.
6. Retry/regenerate must overwrite existing assistant slot for both text and attachment flows.
7. PDF upload `/Users/chan/Downloads/labos_test.pdf` must show upload progress, indexing state transition, and grounded QA without session reattach.
8. Remaining-context ring must track real context; auto-compaction must increase remaining context after low-headroom state.
9. Hub defaults must resolve to provider `openai-codex`, model `gpt-5.3-codex`, thinking `medium`.
10. Message lifecycle regression: no stuck flashing `Thinking...` after response appears, including leave-and-return.

## Test Architecture

### 1) New E2E Test Target
- Add iOS UI test target: `LabOSE2ETests`.
- Source root: `Tests/LabOSE2ETests`.
- Tests run with `xcodebuild test` on iOS simulator.

### 2) Human-Step Runner
Each scenario is executed as steps with strict sequence:
1. Action (tap/type/upload/navigation)
2. Condition-based wait (no fixed sleeps unless fallback)
3. Assertions (UI + backend state + optional filesystem)
4. Screenshot capture
5. Step artifact logging

If any step fails, test fails immediately.

### 3) Verification Layers
- UI layer: XCUITest assertions on visible state and interactions.
- Hub probe layer: sidecar client probes `projects/sessions/artifacts/context` methods and events.
- Filesystem layer: direct checks under Hub state dir (`projects/<projectId>`) for storage/deletion invariants.
- Screenshot layer: step-level screenshot artifact for every major transition.

### 4) Assertion Style
- Live model outputs use semantic contract assertions, not exact phrase equality.
- Required concepts/keywords are checked with tolerant matching.
- For structured prompts, parse JSON if available; otherwise fallback to semantic-keyword contract.

### 5) Blocking Visual Validation
Per-step screenshots are mandatory artifacts.

Optional strict mode:
- Send screenshot + expected step + observed UI facts to `codex exec -i ...`.
- Parse verdict JSON (`pass`, `reason`, `mismatches`).
- If verdict fails or is invalid, fail the step immediately.

Baseline mode still blocks on deterministic XCTest UI assertions even without external visual model validation.

## Scenario Catalog

### A. Settings and Connectivity
`E2E_Settings_HubAndHPC`
- Open settings from Home.
- Enter Hub URL/token, save, connect, disconnect, reconnect.
- Enter/save HPC partition/account/qos.
- Relaunch app and verify values persist.

Pass criteria:
- Connection status changes are reflected in UI.
- Persisted values survive relaunch.

### B. Project Lifecycle and Storage Isolation
`E2E_ProjectCreateDelete_FilesystemDeletion`
- Create project A and project B.
- Upload distinct files to both.
- Assert each has unique `projectId` and isolated directory under `stateDir/projects/<projectId>`.
- Delete project A.
- Assert project A API records are gone and `stateDir/projects/<projectAId>` is physically removed recursively.
- Assert project B remains intact.

### C. Project Page Upload Boundary Rules
`E2E_ProjectPage_ComposerFileBoundary`
- Verify project file badge shows `Add new files` or count text.
- Upload via project badge path and verify files appear as project uploads.
- Add attachments via composer plus and verify they remain session-scoped only.

Pass criteria:
- Project uploads are controlled via project badge flow.
- Composer attachments do not mutate project upload catalog.

### D. Plain Text Messaging
`E2E_TextMessage_Response`
- Send plain text in session.
- Verify assistant response arrives.
- Verify lifecycle closes and stale pending indicators do not remain.

### E. Photo Attachments with Thumbnail Requirement
`E2E_ThumbnailPhotoMessage_GroundedResponse`
- Attach photo in composer.
- Verify pre-send thumbnail preview (not filename-only chip).
- Send prompt.
- Verify grounded response references visual content intent.

Note:
- This test is intentionally strict and should fail until thumbnail preview behavior is implemented.

### F. Retry and Regenerate Overwrite Semantics
`E2E_RetryRegenerate_OverwriteSemantics`
- For plain text and attachment messages:
  - Trigger assistant retry.
  - Trigger retry with different model.
  - Trigger user-message retry/overwrite path.
- Verify regenerated assistant output overwrites same logical slot (`assistant i`) and does not append as `assistant i+1`.

### G. PDF Upload, Indexing, and Grounded QA
`E2E_PDFUpload_IndexingToGroundedQA`
- Upload `/Users/chan/Downloads/labos_test.pdf` into project files.
- Verify upload progress indicator.
- Verify index status transitions:
  - processing/indexing (blue)
  - indexed (green)
- Ask content question without attaching the PDF to session message.
- Verify answer is grounded in indexed content (keywords like `single-cell`, `mosaic integration`).

### H. Context Ring and Auto-Compaction
`E2E_AutoCompaction_ContextRecovery`
- Drive session near context threshold (target <=20% remaining).
- Verify context ring reflects low remaining context.
- Continue conversation until Hub auto-compaction triggers.
- Verify remaining context increases after compaction.
- Verify compaction evidence from transcript summary marker and refreshed context stats.

### I. Hub Defaults Policy
`E2E_DefaultModelPolicy`
- Verify `models.current` resolves to default provider/model policy:
  - provider `openai-codex`
  - model `gpt-5.3-codex`
  - thinking default `medium`

### J. Stuck Thinking Regression
`E2E_NoStuckThinkingIndicator_Regression`
- Reproduce sequence:
  - send message
  - navigate away
  - return to session
- If assistant response exists, verify no persistent flashing `Thinking...` remains.
- Validate state closure through both UI and gateway lifecycle consistency.

## Blocking-First Priority Order
1. `E2E_ThumbnailPhotoMessage_GroundedResponse`
2. `E2E_NoStuckThinkingIndicator_Regression`
3. `E2E_ProjectCreateDelete_FilesystemDeletion`
4. `E2E_PDFUpload_IndexingToGroundedQA`

## Data, Fixtures, and Environment
- Live Hub required and reachable from simulator.
- Test account/provider credentials configured for live model access.
- Required local test asset: `/Users/chan/Downloads/labos_test.pdf`.
- Optional image fixtures for attachment scenarios under test assets directory.

## Flake Resistance and Determinism Controls
1. Condition-based waits for UI/event states (timeouts with diagnostics).
2. One scenario per isolated test project namespace.
3. Explicit cleanup hooks (project/session teardown where applicable).
4. Retry only for known transient transport failures, not assertion failures.
5. Detailed failure payloads with screenshot + last observed Hub events.

## Artifact and Reporting Design
Per test run, store:
- Step screenshots
- Step JSON logs (action/wait/assert/elapsed)
- Hub probe snapshots/events
- Filesystem snapshots for project path checks
- Final summary with first failing step and root assertion

## Risks and Mitigations
1. Live model variance can cause semantic assertion drift.
- Mitigation: concept-level assertions and prompt templates with stronger structure.

2. Network timing instability can produce false negatives.
- Mitigation: condition-based waits and observable event gates.

3. UI changes can break locator stability.
- Mitigation: add explicit accessibility identifiers in app views as part of implementation.

4. External dependency failures (Hub down, auth expired).
- Mitigation: startup preflight checks with immediate fail-fast and actionable diagnostics.

## Exit Criteria
The design is complete when:
1. New E2E target and harness are in place.
2. Blocking-first scenarios run and produce deterministic pass/fail artifacts.
3. Failing tests clearly identify either product defects or test-environment faults.
4. Regression classes above are protected by automated gates.

## Approved Decisions
- Primary gate is full live-model E2E.
- Physical on-disk deletion is required validation for project deletion.
- Context compaction validation is auto-compaction only.
- Thumbnail photo preview is a strict test requirement.
