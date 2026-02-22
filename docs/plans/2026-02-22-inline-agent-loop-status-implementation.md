# Inline Agent Loop Status Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Render Codex-style inline agent process status in the transcript (thinking/tool loop) with deterministic phase transitions and a persisted collapsed summary attached to the assistant turn.

**Architecture:** Add an AppStore-backed turn state machine keyed by session and assistant message IDs, then render process status inline with assistant output instead of using a bottom overlay card. Status rows are gray (`.secondary`), assistant response text remains normal contrast. Tool events use hybrid labeling (family templates + payload fallback), and completed turns persist as collapsed summaries with expandable details.

**Tech Stack:** Swift 6, SwiftUI, XCTest, existing `GatewayClient` streaming events (`agent.stream.lifecycle`, `agent.stream.tool_event`, `agent.stream.assistant_delta`).

---

### Task 1: Add Process Models for Inline Turn Status

**Files:**
- Modify: `Sources/LabOSCore/Models.swift`
- Test: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`

**Step 1: Write the failing test**

Add model-shape assertions that reference new types and fields used by AppStore tests:

```swift
func testInlineProcessSummaryModelShapeCompiles() {
    let summary = AssistantProcessSummary(
        assistantMessageID: UUID(),
        headline: "Explored 1 search",
        entries: [],
        familyCounts: [.search: 1]
    )
    XCTAssertEqual(summary.familyCounts[.search], 1)
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreLiveActivityTests/testInlineProcessSummaryModelShapeCompiles`
Expected: FAIL with unknown type/member errors.

**Step 3: Write minimal implementation**

Add these types in `Sources/LabOSCore/Models.swift`:

```swift
public enum ProcessActionFamily: String, Hashable, Codable, Sendable, CaseIterable {
    case search, list, read, write, exec, other
}

public enum ProcessEntryState: String, Hashable, Codable, Sendable {
    case active
    case completed
    case failed
}

public struct ProcessEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let toolCallID: String?
    public let family: ProcessActionFamily
    public var activeText: String
    public var completedText: String
    public var state: ProcessEntryState
    public let createdAt: Date
}

public struct AssistantProcessSummary: Hashable, Codable, Sendable {
    public let assistantMessageID: UUID
    public var headline: String
    public var entries: [ProcessEntry]
    public var familyCounts: [ProcessActionFamily: Int]
}

public enum AgentTurnPhase: String, Hashable, Sendable {
    case thinking, toolCalling, responding, completed, failed
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreLiveActivityTests/testInlineProcessSummaryModelShapeCompiles`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/Models.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "feat(core): add inline agent process models"
```

---

### Task 2: Red Tests for Loop State Machine Semantics

**Files:**
- Modify: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`
- Modify: `Sources/LabOSCore/AppStore.swift` (later in green step)

**Step 1: Write the failing tests**

Add tests covering required loop behavior:

```swift
func testThinkingClearsImmediatelyOnFirstAssistantDelta() {
    // lifecycle start -> thinking
    // assistant delta -> responding
    // assert active display is no longer "Thinking..."
}

func testToolStartThenEndConvertsIngToEdAndReturnsToThinking() {
    // lifecycle start
    // tool start "search" => "Searching..."
    // tool end => "Searched ..." entry completed, active line back to "Thinking..."
}

func testLifecycleEndPersistsCollapsedSummaryForAssistantMessage() {
    // run through start -> tool events -> delta -> end
    // assert summary exists for assistant message id
    // assert grouped counts by family
}

func testToolFamiliesGroupedInSummaryHeadline() {
    // 1 search + 2 list => headline "Explored 1 search, 2 lists"
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: FAIL on missing AppStore API/state and assertions.

**Step 3: Write minimal implementation scaffolding**

In `Sources/LabOSCore/AppStore.swift`, add storage/accessors referenced by tests:

```swift
@Published public private(set) var activeInlineProcessBySession: [UUID: ActiveInlineProcess] = [:]
@Published public private(set) var persistedProcessSummaryByMessageID: [UUID: AssistantProcessSummary] = [:]

public func activeInlineProcess(for sessionID: UUID) -> ActiveInlineProcess? { ... }
public func persistedProcessSummary(for assistantMessageID: UUID) -> AssistantProcessSummary? { ... }
```

**Step 4: Run tests to verify partial pass/fail**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: still FAIL (transition logic not yet implemented), compile succeeds.

**Step 5: Commit**

```bash
git add Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift Sources/LabOSCore/AppStore.swift
git commit -m "test(core): add failing tests for inline agent loop semantics"
```

---

### Task 3: Implement Event-Driven Loop Transitions in AppStore

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Test: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`

**Step 1: Write one failing test slice for lifecycle+delta transition**

Target only first transition:
- start => active thinking
- first delta => responding and thinking cleared.

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreLiveActivityTests/testThinkingClearsImmediatelyOnFirstAssistantDelta`
Expected: FAIL.

**Step 3: Write minimal implementation**

Implement deterministic handlers:

```swift
private func applyLifecycle(_ payload: LifecyclePayload) {
    switch normalizedPhase(payload.phase) {
    case "start": beginTurn(sessionID: payload.sessionId, runID: payload.agentRunId)
    case "end": finalizeTurn(sessionID: payload.sessionId, failure: nil)
    case "error": finalizeTurn(sessionID: payload.sessionId, failure: payload.error)
    default: break
    }
}

private func applyAssistantDelta(_ payload: AssistantDeltaPayload) {
    bindAssistantMessageIfNeeded(sessionID: payload.sessionId, messageID: payload.messageId)
    transitionToResponding(sessionID: payload.sessionId) // clears thinking line immediately
    // existing delta append behavior stays
}

private func applyToolEvent(_ payload: ToolEventPayload) {
    if isStart(payload.phase) {
        startToolEntry(sessionID: payload.sessionId, payload: payload)
    } else if isEnd(payload.phase) {
        completeToolEntry(sessionID: payload.sessionId, payload: payload)
        transitionBackToThinking(sessionID: payload.sessionId)
    } else if isError(payload.phase) {
        failToolEntry(sessionID: payload.sessionId, payload: payload)
        transitionBackToThinking(sessionID: payload.sessionId)
    }
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: transition tests PASS or move to next minimal failing case.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "feat(core): implement inline thinking-tool loop transitions"
```

---

### Task 4: Implement Hybrid Tool Labeling (`-ing` -> `-ed`) + Family Grouping

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Test: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`

**Step 1: Write failing tests for labels and grouping**

Add tests asserting:
- `web.search_query` start => `Searching...`
- end => entry text becomes `Searched ...`
- summary headline groups as `Explored 1 search, 2 lists`.

**Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStoreLiveActivityTests/testToolFamiliesGroupedInSummaryHeadline`
Expected: FAIL.

**Step 3: Write minimal implementation**

Add family and phrase helpers in AppStore:

```swift
private func family(for tool: String, summary: String) -> ProcessActionFamily { ... }
private func activePhrase(for family: ProcessActionFamily, fallback: String) -> String { ... }   // -ing
private func completedPhrase(for family: ProcessActionFamily, fallback: String) -> String { ... } // -ed
private func summaryHeadline(from counts: [ProcessActionFamily: Int]) -> String { ... }
```

Behavior:
- Hybrid: template by family, fallback to payload summary when unrecognized.
- Group counts by family.

**Step 4: Run tests to verify they pass**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: PASS for new label/grouping tests.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "feat(core): add hybrid tool labeling and family-grouped summaries"
```

---

### Task 5: Persist Completed Summary by Assistant Message ID

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Test: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`

**Step 1: Write failing test**

Test that on lifecycle end, summary is attached to assistant message ID and survives completion.

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreLiveActivityTests/testLifecycleEndPersistsCollapsedSummaryForAssistantMessage`
Expected: FAIL.

**Step 3: Write minimal implementation**

In finalization path:

```swift
private func finalizeTurn(sessionID: UUID, failure: GatewayError?) {
    guard let turn = activeInlineProcessBySession[sessionID] else { return }
    if let messageID = turn.assistantMessageID {
        persistedProcessSummaryByMessageID[messageID] = AssistantProcessSummary(
            assistantMessageID: messageID,
            headline: summaryHeadline(from: turn.familyCounts),
            entries: turn.entries,
            familyCounts: turn.familyCounts
        )
    }
    activeInlineProcessBySession[sessionID] = nil
}
```

**Step 4: Run test to verify it passes**

Run: `swift test --filter AppStoreLiveActivityTests/testLifecycleEndPersistsCollapsedSummaryForAssistantMessage`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "feat(core): persist collapsed process summary per assistant message"
```

---

### Task 6: Remove Bottom Process Card Rendering

**Files:**
- Modify: `Sources/LabOSApp/Views/Session/SessionChatView.swift`

**Step 1: Write failing UI behavior test (if harness available), otherwise red assertion in core test**

If no UI test harness, add/store assertion that bottom-card-only state no longer required and inline state is available.

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: FAIL/RED for removed dependency assumptions.

**Step 3: Write minimal implementation**

In `SessionChatView`:
- Remove `showsLiveAgentCard` overlay branch.
- Remove `liveAgentActivityCard(...)` and associated height preference coupling.
- Keep composer overlay independent from inline process state.

**Step 4: Run test/build to verify pass**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Session/SessionChatView.swift
git commit -m "refactor(ui): remove bottom agent activity card"
```

---

### Task 7: Add Inline Process View Component (Gray Rows, Blink, Collapsible)

**Files:**
- Create: `Sources/LabOSApp/Views/Session/AssistantProcessInlineView.swift`
- Modify: `Sources/LabOSApp/Views/Session/MessageBubbleView.swift`

**Step 1: Write failing compile/test hook**

Reference new component from `MessageBubbleView` before implementation.

**Step 2: Run to verify failure**

Run: `swift test --filter AppStoreMessageActionsTests`
Expected: compile FAIL due to missing `AssistantProcessInlineView`.

**Step 3: Write minimal implementation**

Create view:

```swift
struct AssistantProcessInlineView: View {
    let activeLine: String?
    let isThinkingBlinking: Bool
    let summary: AssistantProcessSummary?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activeLine {
                HStack(spacing: 6) { /* dot + gray text */ }
                    .foregroundStyle(.secondary)
                    .opacity(isThinkingBlinking ? 0.65 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isThinkingBlinking)
            }
            if let summary {
                Button { expanded.toggle() } label: {
                    HStack { Text(summary.headline); Spacer(); Image(systemName: expanded ? "chevron.down" : "chevron.right") }
                }
                .foregroundStyle(.secondary)

                if expanded {
                    ForEach(summary.entries) { entry in
                        Text(entry.state == .completed ? entry.completedText : entry.activeText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
```

**Step 4: Run build/tests to verify pass**

Run: `swift test --filter AppStoreMessageActionsTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Session/AssistantProcessInlineView.swift Sources/LabOSApp/Views/Session/MessageBubbleView.swift
git commit -m "feat(ui): add inline gray process indicator component"
```

---

### Task 8: Wire Inline Process to Assistant Message Turn

**Files:**
- Modify: `Sources/LabOSApp/Views/Session/SessionChatView.swift`
- Modify: `Sources/LabOSApp/Views/Session/MessageBubbleView.swift`
- Modify: `Sources/LabOSCore/AppStore.swift`

**Step 1: Write failing behavior test**

Add test asserting accessor resolves process data by message/session:

```swift
func testInlineProcessDataResolvesForAssistantMessage() {
    // create lifecycle/tool/delta/end flow
    // assert store returns summary for assistant message ID
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter AppStoreLiveActivityTests/testInlineProcessDataResolvesForAssistantMessage`
Expected: FAIL.

**Step 3: Write minimal implementation**

- Add AppStore helper:

```swift
public func inlineProcessForAssistantMessage(sessionID: UUID, messageID: UUID) -> (activeLine: String?, isBlinking: Bool, summary: AssistantProcessSummary?)
```

- In `SessionChatView`, for assistant messages pass process payload into `MessageBubbleView`.
- In `MessageBubbleView`, render `AssistantProcessInlineView` in transcript area (not composer overlay).

Placement rules:
- Active line appears in assistant turn area while running.
- Persisted summary appears with that assistant message after completion.

**Step 4: Run tests/build**

Run:
- `swift test --filter AppStoreLiveActivityTests`
- `swift test --filter AppStoreMessageActionsTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Session/SessionChatView.swift Sources/LabOSApp/Views/Session/MessageBubbleView.swift Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "feat(ui): render inline process loop with persisted summary per assistant turn"
```

---

### Task 9: Cleanup Legacy State and Ensure No Regressions

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Modify: `Tests/LabOSCoreTests/AppStoreSemanticsTests.swift` (only if needed)
- Modify: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`

**Step 1: Write failing cleanup tests**

Cover deletion/disconnect cleanup of new process dictionaries:
- session delete clears active/persisted process state.
- project delete clears state.
- disconnect clears active session process state.

**Step 2: Run test to verify fail**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: FAIL.

**Step 3: Implement minimal cleanup hooks**

Add cleanup in:
- `disconnectGateway()`
- `removeSessionLocally(...)`
- `removeProjectLocally(...)`
- overwrite/resend paths that prune downstream assistant summaries when prior thread is truncated.

**Step 4: Run tests to verify pass**

Run: `swift test --filter AppStoreLiveActivityTests`
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift
git commit -m "chore(core): clean inline process state on disconnect/delete paths"
```

---

### Task 10: Full Verification + Manual QA

**Files:**
- Modify (if needed): `docs/plans/2026-02-22-inline-agent-loop-status-implementation.md`

**Step 1: Run full Swift tests**

Run: `swift test`
Expected: PASS all existing semantics tests, including:
- `testDeleteSessionKeepsArtifacts`
- `testDeleteProjectWipesSessionsRunsAndArtifacts`
- `testCancelPlanDoesNotCreateRun`
- `testUploadedFilesAreSeparatedFromGeneratedResults`

**Step 2: Run simulator build**

Run: `xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination 'id=2687AC4E-85D8-4922-976D-70BCC1C0EBB3' build`
Expected: `** BUILD SUCCEEDED **`.

**Step 3: Manual QA script (simulator)**

1. Send a prompt that triggers tools.
2. Verify inline gray row shows `Thinking...`.
3. Verify tool start shows `-ing` and tool completion shows `-ed`.
4. Verify loop can repeat multiple times before final text.
5. Verify first assistant token immediately clears active `Thinking...` state.
6. Verify final assistant text is normal contrast.
7. Verify persisted collapsed summary exists for that assistant turn and expands to gray detail rows.
8. Verify nothing is shown above the composer as process status.

**Step 4: Commit final verification note**

```bash
git add docs/plans/2026-02-22-inline-agent-loop-status-implementation.md
git commit -m "docs: record verification checklist for inline agent loop status"
```

---

## Notes for Executor

- Prefer small commits per task.
- Keep old APIs temporarily only when needed to avoid large breakage; remove dead code in final cleanup.
- Preserve existing message actions (copy/edit/retry/branch), code rendering, and semantics invariants.
- If this workspace is not a git repo snapshot, still execute tasks and verification commands; skip commits with explicit note in execution log.

