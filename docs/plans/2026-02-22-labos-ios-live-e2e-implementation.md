# LabOS iOS Live E2E Test Suite Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a blocking, human-like iOS E2E suite that validates live Hub workflows, screenshot evidence, and regression coverage for messaging, uploads/indexing, compaction, and project lifecycle.

**Architecture:** Add a dedicated `LabOSE2ETests` UI test target, a reusable E2E harness (`StepRunner`, condition waits, screenshot recorder, Hub probe), and scenario tests mapped to approved workflows. Strengthen app observability with accessibility identifiers and targeted UI affordances (thumbnail preview, indexing badge/progress) so UI automation can assert reliable state transitions. Fix stale inline process reconciliation so `Thinking...` cannot persist after assistant completion.

**Tech Stack:** SwiftUI, XCTest/XCUITest, LabOSCore `GatewayClient`, Fastify Hub API/WS protocol, local filesystem assertions, `xcodebuild`, `xcodegen`.

---

Execution discipline for all tasks:
- Apply @superpowers:test-driven-development in strict red-green-refactor order.
- Run @superpowers:verification-before-completion before claiming a task is done.
- Keep commits focused and small (one task per commit).

Assumptions:
- Simulator destination exists: `platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2`.
- Live Hub running and reachable at `ws://127.0.0.1:8787/ws`.
- Test PDF exists at `/Users/chan/Downloads/labos_test.pdf`.

Common command shortcut used below:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
```

### Task 1: Add UI E2E Target Scaffold

**Files:**
- Modify: `project.yml`
- Modify: `LabOS.xcodeproj/project.pbxproj` (regenerated)
- Create: `Tests/LabOSE2ETests/E2ESmokeTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2ESmokeTests: XCTestCase {
    func testLaunchesHome() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 8))
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2ESmokeTests/testLaunchesHome test
```
Expected: FAIL because `LabOSE2ETests` target does not exist yet.

**Step 3: Write minimal implementation**
- Add `LabOSE2ETests` (`bundle.ui-testing`) target in `project.yml` with source root `Tests/LabOSE2ETests` and dependency on `LabOSApp`.
- Run `xcodegen generate` to update `LabOS.xcodeproj`.

**Step 4: Run test to verify it passes**

Run same `xcodebuild` command.
Expected: PASS for `testLaunchesHome`.

**Step 5: Commit**

```bash
git add project.yml LabOS.xcodeproj/project.pbxproj Tests/LabOSE2ETests/E2ESmokeTests.swift
git commit -m "test: add LabOSE2ETests target scaffold"
```

### Task 2: Add Stable Accessibility Identifiers for E2E Controls

**Files:**
- Modify: `Sources/LabOSApp/Views/Home/HomeView.swift`
- Modify: `Sources/LabOSApp/Views/Project/ProjectPageView.swift`
- Modify: `Sources/LabOSApp/Views/Session/SessionChatView.swift`
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift`
- Test: `Tests/LabOSE2ETests/E2EAccessibilityTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EAccessibilityTests: XCTestCase {
    func testCriticalControlsHaveStableIdentifiers() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["home.settings.button"].waitForExistence(timeout: 8))
        app.buttons["home.settings.button"].tap()

        XCTAssertTrue(app.textFields["settings.gateway.url"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.gateway.token"].exists)
        XCTAssertTrue(app.buttons["settings.gateway.save"].exists)
        XCTAssertTrue(app.buttons["settings.gateway.connect"].exists)
        XCTAssertTrue(app.textFields["settings.hpc.partition"].exists)
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EAccessibilityTests/testCriticalControlsHaveStableIdentifiers test
```
Expected: FAIL because identifiers are missing.

**Step 3: Write minimal implementation**
- Add `.accessibilityIdentifier(...)` to all controls used by E2E flows, including settings fields/buttons, project file badge, composer plus, send button, retry controls, and context ring.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Home/HomeView.swift Sources/LabOSApp/Views/Project/ProjectPageView.swift Sources/LabOSApp/Views/Session/SessionChatView.swift Sources/LabOSApp/Views/Shared/InlineComposerView.swift Tests/LabOSE2ETests/E2EAccessibilityTests.swift
git commit -m "test: add stable accessibility identifiers for E2E flows"
```

### Task 3: Build E2E Harness (Step Runner, Waits, Screenshots, Hub Probe)

**Files:**
- Create: `Tests/LabOSE2ETests/Support/E2EStepRunner.swift`
- Create: `Tests/LabOSE2ETests/Support/E2EWait.swift`
- Create: `Tests/LabOSE2ETests/Support/E2EScreenshotRecorder.swift`
- Create: `Tests/LabOSE2ETests/Support/E2EHubProbe.swift`
- Create: `Tests/LabOSE2ETests/Support/E2EPaths.swift`
- Test: `Tests/LabOSE2ETests/E2EHarnessTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EHarnessTests: XCTestCase {
    func testStepRunnerCapturesScreenshotAndLog() throws {
        let app = XCUIApplication()
        app.launch()

        let runner = E2EStepRunner(testCase: self, app: app)
        try runner.step("home-visible") {
            XCTAssertTrue(app.staticTexts["Home"].waitForExistence(timeout: 5))
        }

        XCTAssertTrue(runner.lastStepArtifactsContain("home-visible"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EHarnessTests/testStepRunnerCapturesScreenshotAndLog test
```
Expected: FAIL (support classes missing).

**Step 3: Write minimal implementation**
- Implement `E2EStepRunner` with strict failure behavior.
- Implement condition-based waiter utility.
- Implement screenshot recorder using `XCUIScreen.main.screenshot()` + `XCTAttachment`.
- Implement Hub probe with:
  - `GatewayClient`-based request helper (`models.current`, `projects.list`, `sessions.context.get`, `artifacts.list`).
  - state-dir resolver (`$LABOS_STATE_DIR` fallback to `~/.labos`).

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/Support/E2EStepRunner.swift Tests/LabOSE2ETests/Support/E2EWait.swift Tests/LabOSE2ETests/Support/E2EScreenshotRecorder.swift Tests/LabOSE2ETests/Support/E2EHubProbe.swift Tests/LabOSE2ETests/Support/E2EPaths.swift Tests/LabOSE2ETests/E2EHarnessTests.swift
git commit -m "test: add reusable E2E harness and Hub probe"
```

### Task 4: Implement Settings Flow E2E Scenario

**Files:**
- Create: `Tests/LabOSE2ETests/E2ESettingsFlowTests.swift`
- Modify: `Sources/LabOSApp/Views/Home/HomeView.swift` (only if missing identifiers)

**Step 1: Write the failing test**

```swift
import XCTest

final class E2ESettingsFlowTests: XCTestCase {
    func testHubAndHpcSettingsSaveConnectAndPersist() throws {
        let app = XCUIApplication()
        app.launch()

        // Fill/save gateway + HPC, connect/disconnect, relaunch, verify persisted values.
        XCTFail("Implement scenario")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2ESettingsFlowTests/testHubAndHpcSettingsSaveConnectAndPersist test
```
Expected: FAIL due placeholder/failing assertions.

**Step 3: Write minimal implementation**
- Implement scenario steps via `E2EStepRunner`.
- Assert visible status transitions and persisted field values after relaunch.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2ESettingsFlowTests.swift Sources/LabOSApp/Views/Home/HomeView.swift
git commit -m "test: add settings E2E flow for Hub and HPC"
```

### Task 5: Implement Project Create/Delete + Physical Deletion E2E

**Files:**
- Create: `Tests/LabOSE2ETests/E2EProjectLifecycleTests.swift`
- Modify: `Sources/LabOSApp/Views/Drawers/ProjectsDrawerView.swift` (identifier hooks if needed)

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EProjectLifecycleTests: XCTestCase {
    func testProjectDeletionRemovesDiskFolderRecursively() throws {
        let app = XCUIApplication()
        app.launch()

        // Create project, upload file, capture projectId via probe,
        // delete project, assert stateDir/projects/<id> is gone.
        XCTFail("Implement scenario")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EProjectLifecycleTests/testProjectDeletionRemovesDiskFolderRecursively test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Implement create/upload/delete flow.
- Use `E2EHubProbe` to map project names to IDs.
- Assert `stateDir/projects/<projectId>` exists after upload and does not exist after delete.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2EProjectLifecycleTests.swift Sources/LabOSApp/Views/Drawers/ProjectsDrawerView.swift
git commit -m "test: add project lifecycle E2E with disk deletion checks"
```

### Task 6: Enforce Project Upload Boundary Rules E2E

**Files:**
- Create: `Tests/LabOSE2ETests/E2EProjectUploadBoundaryTests.swift`
- Modify: `Sources/LabOSApp/Views/Project/ProjectPageView.swift` (identifier hooks if needed)
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift` (identifier hooks if needed)

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EProjectUploadBoundaryTests: XCTestCase {
    func testProjectBadgeOwnsProjectUploadsAndComposerPlusIsSessionScoped() throws {
        let app = XCUIApplication()
        app.launch()
        XCTFail("Implement scenario")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EProjectUploadBoundaryTests/testProjectBadgeOwnsProjectUploadsAndComposerPlusIsSessionScoped test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Upload through project badge and assert project file count increases.
- Add attachment via composer plus and assert it appears only in session attachments UI, not project file count.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2EProjectUploadBoundaryTests.swift Sources/LabOSApp/Views/Project/ProjectPageView.swift Sources/LabOSApp/Views/Shared/InlineComposerView.swift
git commit -m "test: add project upload boundary E2E scenario"
```

### Task 7: Add Composer Thumbnail Preview Above Input Row

**Files:**
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift`
- Test: `Tests/LabOSE2ETests/E2EPhotoAttachmentTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EPhotoAttachmentTests: XCTestCase {
    func testPhotoAttachmentShowsThumbnailBeforeSend() throws {
        let app = XCUIApplication()
        app.launch()

        // Attach image
        // Assert thumbnail preview element exists above composer input
        XCTAssertTrue(app.images["composer.attachment.thumbnail.0"].waitForExistence(timeout: 8))
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EPhotoAttachmentTests/testPhotoAttachmentShowsThumbnailBeforeSend test
```
Expected: FAIL because composer currently shows chips, not inline thumbnails.

**Step 3: Write minimal implementation**
- In `InlineComposerView.chatComposer`, render image thumbnail previews in composer area (above input field).
- Keep file attachments as chips.
- Add identifiers:
  - `composer.attachment.thumbnail.<index>`
  - `composer.attachment.filechip.<index>`

Example rendering snippet:
```swift
if !imageAttachments.isEmpty {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            ForEach(Array(imageAttachments.enumerated()), id: \.offset) { index, attachment in
                composerImageThumbnail(attachment)
                    .accessibilityIdentifier("composer.attachment.thumbnail.\(index)")
            }
        }
    }
}
```

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/InlineComposerView.swift Tests/LabOSE2ETests/E2EPhotoAttachmentTests.swift
git commit -m "feat: show image thumbnails in composer attachment preview"
```

### Task 8: Add Photo Grounding E2E Scenario

**Files:**
- Modify: `Tests/LabOSE2ETests/E2EPhotoAttachmentTests.swift`

**Step 1: Write the failing test**

```swift
func testPhotoMessageGetsGroundedAssistantReply() throws {
    // send attached photo prompt, wait for assistant,
    // assert semantic grounding contract (non-empty, references visual/object cues)
    XCTFail("Implement scenario")
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EPhotoAttachmentTests/testPhotoMessageGetsGroundedAssistantReply test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Implement full send/wait/assert flow.
- Use semantic assertion helper:
  - non-empty assistant text
  - contains at least one image-grounding token from configured set.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2EPhotoAttachmentTests.swift
git commit -m "test: add grounded photo message E2E scenario"
```

### Task 9: Add Retry/Regenerate Overwrite Semantics E2E

**Files:**
- Create: `Tests/LabOSE2ETests/E2ERetryOverwriteTests.swift`
- Modify: `Sources/LabOSApp/Views/Session/MessageBubbleView.swift` (identifier hooks for retry/model menu)

**Step 1: Write the failing test**

```swift
import XCTest

final class E2ERetryOverwriteTests: XCTestCase {
    func testRetryOverwritesAssistantSlotForTextAndAttachmentMessages() throws {
        let app = XCUIApplication()
        app.launch()
        XCTFail("Implement scenario")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2ERetryOverwriteTests/testRetryOverwritesAssistantSlotForTextAndAttachmentMessages test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Add stable IDs on retry controls.
- Implement scenario to capture assistant message count and ID ordering before/after retry.
- Assert no net +1 assistant message append for retried turn.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2ERetryOverwriteTests.swift Sources/LabOSApp/Views/Session/MessageBubbleView.swift
git commit -m "test: add retry/regenerate overwrite semantics E2E"
```

### Task 10: Add Indexing UX Cues and PDF Grounded QA E2E

**Files:**
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift`
- Create: `Tests/LabOSE2ETests/E2EPDFIndexingTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EPDFIndexingTests: XCTestCase {
    func testPdfUploadShowsProgressThenIndexedAndSupportsGroundedQa() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.otherElements["project.upload.progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Indexing"].exists)
        XCTAssertTrue(app.staticTexts["Indexed"].waitForExistence(timeout: 120))

        XCTFail("Implement grounded QA assertion")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EPDFIndexingTests/testPdfUploadShowsProgressThenIndexedAndSupportsGroundedQa test
```
Expected: FAIL because current UI lacks explicit progress/Indexing cues and scenario code.

**Step 3: Write minimal implementation**
- Update project files row rendering:
  - Processing label text to `Indexing`.
  - Add visible progress circle/spinner for processing status.
  - Add accessibility IDs for status and progress.
- Implement PDF scenario with `/Users/chan/Downloads/labos_test.pdf` upload + grounded QA assertion tokens (`single-cell`, `mosaic integration`).

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/InlineComposerView.swift Tests/LabOSE2ETests/E2EPDFIndexingTests.swift
git commit -m "feat: add indexing progress cues and PDF grounded QA E2E"
```

### Task 11: Add Auto-Compaction and Context Ring E2E

**Files:**
- Create: `Tests/LabOSE2ETests/E2EAutoCompactionTests.swift`
- Modify: `Tests/LabOSE2ETests/Support/E2EHubProbe.swift` (history/context helpers)

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EAutoCompactionTests: XCTestCase {
    func testAutoCompactionIncreasesRemainingContext() throws {
        let app = XCUIApplication()
        app.launch()
        XCTFail("Implement context drive + compaction assertions")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EAutoCompactionTests/testAutoCompactionIncreasesRemainingContext test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Add helper to poll `sessions.context.get` for remaining tokens.
- Drive context with repeated long prompts until <=20% remains.
- Continue until compaction marker appears in history (`[LABOS_COMPACT_SUMMARY v1 ...]`).
- Assert remaining context increases after compaction and context ring updates.

**Step 4: Run test to verify it passes**
Run same `xcodebuild` command.
Expected: PASS.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2EAutoCompactionTests.swift Tests/LabOSE2ETests/Support/E2EHubProbe.swift
git commit -m "test: add auto-compaction and context recovery E2E"
```

### Task 12: Set Hub Default Provider/Model Policy and Test It

**Files:**
- Modify: `packages/hub/src/model.ts`
- Modify: `packages/hub/src/commands/config.ts`
- Create: `Tests/LabOSE2ETests/E2EHubDefaultsTests.swift`
- Test: `packages/hub/tests/policy.test.mjs`

**Step 1: Write the failing test**

```js
import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveHubProvider } from '../src/model.js';

test('default provider/model policy prefers openai-codex gpt-5.3-codex', () => {
  const resolved = resolveHubProvider({});
  assert.equal(resolved.provider, 'openai-codex');
  assert.equal(resolved.defaultModelId, 'gpt-5.3-codex');
});
```

**Step 2: Run test to verify it fails**

Run:
```bash
pnpm -C packages/hub test -- --run tests/policy.test.mjs
```
Expected: FAIL (current fallback defaults to `openai`).

**Step 3: Write minimal implementation**
- Update default fallback in `resolveHubProvider` to `openai-codex` with default model `gpt-5.3-codex` when config/env absent.
- Update wizard defaults in `config.ts` provider/model selection defaults.
- Add iOS E2E test querying `models.current` and composer default thinking chip (`Standard`/`Medium` mapping) to verify policy.

**Step 4: Run test to verify it passes**

Run:
```bash
pnpm -C packages/hub test -- --run tests/policy.test.mjs
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EHubDefaultsTests/testDefaultProviderModelAndThinkingPolicy test
```
Expected: PASS.

**Step 5: Commit**

```bash
git add packages/hub/src/model.ts packages/hub/src/commands/config.ts packages/hub/tests/policy.test.mjs Tests/LabOSE2ETests/E2EHubDefaultsTests.swift
git commit -m "feat: enforce hub default model policy and add coverage"
```

### Task 13: Fix Stuck Thinking Regression in AppStore Reconciliation

**Files:**
- Modify: `Sources/LabOSCore/AppStore.swift`
- Modify: `Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift`
- Create: `Tests/LabOSE2ETests/E2EThinkingLifecycleRegressionTests.swift`

**Step 1: Write the failing test**

```swift
@MainActor
func testHistorySnapshotClearsPendingInlineProcessEvenWithStalePendingEchoWhenAssistantReplyExists() async {
    let defaults = UserDefaults(suiteName: "LabOS.StalePendingEcho")!
    defaults.removePersistentDomain(forName: "LabOS.StalePendingEcho")
    let store = AppStore(bootstrapDemo: false, userDefaults: defaults)

    // Local setup first (gateway not configured)
    let project = await store.createProject(name: "P")!
    let session = await store.createSession(projectID: project.id)!

    // Enable gateway mode after local creation so sendMessage creates pending local echo.
    store.saveGatewaySettings(wsURLString: "ws://127.0.0.1:8787/ws", token: "fake")
    store.sendMessage(projectID: project.id, sessionID: session.id, text: "hello")

    let user = ChatMessage(sessionID: session.id, role: .user, text: "hello")
    let assistant = ChatMessage(sessionID: session.id, role: .assistant, text: "done")
    store.applySessionHistorySnapshot(projectID: project.id, sessionID: session.id, messages: [user, assistant], fetchedAt: .now)

    XCTAssertNil(store.pendingInlineProcess(for: session.id))
    XCTAssertNil(store.activeInlineProcess(for: session.id))
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
swift test --filter AppStoreLiveActivityTests/testHistorySnapshotClearsPendingInlineProcessEvenWithStalePendingEchoWhenAssistantReplyExists
```
Expected: FAIL reproducing stale inline process.

**Step 3: Write minimal implementation**
- In `reconcileInlineProcessAfterHistorySync`, when a post-user assistant reply is present:
  - clear stale `pendingLocalUserEchosBySession[sessionID]`.
  - finalize/clear inline process regardless of pending echo guard.
- Keep existing behavior for truly pending user-last state.

**Step 4: Run test to verify it passes**

Run:
```bash
swift test --filter AppStoreLiveActivityTests/testHistorySnapshotClearsPendingInlineProcessEvenWithStalePendingEchoWhenAssistantReplyExists
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EThinkingLifecycleRegressionTests/testNoStuckThinkingAfterLeaveAndReturn test
```
Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSCore/AppStore.swift Tests/LabOSCoreTests/AppStoreLiveActivityTests.swift Tests/LabOSE2ETests/E2EThinkingLifecycleRegressionTests.swift
git commit -m "fix: clear stale inline thinking state after assistant history sync"
```

### Task 14: Full Suite Aggregation and Developer Entry Points

**Files:**
- Create: `Tests/LabOSE2ETests/E2EFullSuiteTests.swift`
- Create: `docs/testing/live-e2e.md`
- Modify: `README.md`

**Step 1: Write the failing test**

```swift
import XCTest

final class E2EFullSuiteTests: XCTestCase {
    func testBlockingScenarioOrderingIsDocumented() {
        XCTFail("Document and enforce ordering")
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests/E2EFullSuiteTests/testBlockingScenarioOrderingIsDocumented test
```
Expected: FAIL.

**Step 3: Write minimal implementation**
- Convert to non-placeholder and encode blocking-first order in suite docs.
- Add runbook commands in `docs/testing/live-e2e.md` and `README.md`.

**Step 4: Run test to verify it passes**

Run:
```bash
export IOS_DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2'
xcodebuild -project LabOS.xcodeproj -scheme LabOSApp -destination "$IOS_DEST" -only-testing:LabOSE2ETests test
swift test
pnpm -C packages/hub test
```
Expected: PASS for targeted suites.

**Step 5: Commit**

```bash
git add Tests/LabOSE2ETests/E2EFullSuiteTests.swift docs/testing/live-e2e.md README.md
git commit -m "docs: add live E2E runbook and suite entry points"
```

## Final Verification Checklist
- `xcodegen generate` completed after target changes.
- `swift test` passes for `LabOSCoreTests`.
- `pnpm -C packages/hub test` passes for Hub policy updates.
- `xcodebuild ... -only-testing:LabOSE2ETests` passes for implemented scenarios.
- Artifacts are produced for each E2E step (screenshots + logs + probe snapshots).

## Notes on Scope Order
Implement in this priority:
1. Thumbnail + photo grounding
2. Stuck thinking regression
3. Project deletion with physical folder checks
4. PDF indexing to grounded QA
5. Remaining scenarios and suite hardening
