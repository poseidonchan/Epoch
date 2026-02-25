# Codex-Like iOS Composer + Shelf Dock Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the iOS composer UI match the Codex app: `+` inside the composer toolbar row, shelf tightly stacked above the composer, and permission/context footer outside the dock; apply to both `SessionChatView` and `ProjectPageView`.

**Architecture:** Introduce a reusable iOS-only `CodexDockView` that owns the bottom scrim + spacing and renders (1) shelf rows (session only) and (2) the composer surface, followed by a footer row outside the dock. Refactor `InlineComposerView`’s `.chatGPT` style into a Codex-matching layout with an internal toolbar row that includes `+`, model/thinking menus, mic, and primary action.

**Tech Stack:** Swift 6, SwiftUI (iOS 17+), LabOSApp views + LabOSCore bindings via `AppStore`.

---

## Design Constraints (Locked)

- iOS only.
- `+` button must be inside the composer (toolbar row), not a separate floating circle.
- Shelf sits immediately above the composer and feels visually connected (shared width/insets, tight spacing, consistent chrome).
- Permission/context footer row remains outside the dock surfaces (below shelf/composer).
- Must apply to both:
  - `Sources/LabOSApp/Views/Session/SessionChatView.swift`
  - `Sources/LabOSApp/Views/Project/ProjectPageView.swift`

## Non-Goals

- Do not change queue/steer/stop behavior; this is UI-only refactor.
- No new test frameworks (snapshot/UI). Verification is `swift test` + manual simulator checks.

---

## Task 1: Add Codex Dock Tokens (Shared Styling)

**Files:**
- Create: `Sources/LabOSApp/Views/Shared/CodexDockTokens.swift`

**Step 1: Add the tokens file**

```swift
#if os(iOS)
import SwiftUI

enum CodexDockTokens {
    static let horizontalInset: CGFloat = 12
    static let stackSpacing: CGFloat = 8
    static let surfaceCornerRadius: CGFloat = 22
    static let surfacePadding: CGFloat = 12
    static let surfaceBorderOpacity: Double = 0.10
    static let surfaceShadowOpacity: Double = 0.08
    static let surfaceShadowRadius: CGFloat = 12
    static let surfaceShadowYOffset: CGFloat = 2

    static func scrimOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.98 : 0.92
    }
}
#endif
```

**Step 2: Build to ensure it compiles**

Run: `swift test`

Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/CodexDockTokens.swift
git commit -m "ui(ios): add codex dock design tokens"
```

---

## Task 2: Create `CodexDockView` (Bottom Dock Container)

**Files:**
- Create: `Sources/LabOSApp/Views/Shared/CodexDockView.swift`

**Step 1: Create `CodexDockView`**

This view renders:
- optional shelf content (already styled as surfaces)
- composer surface
- footer row (outside surfaces)
- a background scrim that fills the bottom safe area

```swift
#if os(iOS)
import SwiftUI

struct CodexDockView<Shelf: View, Composer: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let shelf: Shelf
    private let composer: Composer
    private let footer: Footer

    init(
        @ViewBuilder shelf: () -> Shelf,
        @ViewBuilder composer: () -> Composer,
        @ViewBuilder footer: () -> Footer
    ) {
        self.shelf = shelf()
        self.composer = composer()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexDockTokens.stackSpacing) {
            shelf
            composer
            footer
        }
        .padding(.horizontal, CodexDockTokens.horizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            Color(.systemBackground)
                .opacity(CodexDockTokens.scrimOpacity(colorScheme))
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
        )
    }
}
#endif
```

**Step 2: Build**

Run: `swift test`

Expected: PASS.

**Step 3: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/CodexDockView.swift
git commit -m "ui(ios): add codex dock container view"
```

---

## Task 3: Refactor `SessionShelfView` To Support Dock Mode

**Files:**
- Modify: `Sources/LabOSApp/Views/Session/SessionShelfView.swift`

**Step 1: Add render mode**

Add:

```swift
enum SessionShelfRenderMode {
    case cards
    case dock
}
```

and a stored property:

```swift
let renderMode: SessionShelfRenderMode
```

Provide a default initializer that preserves existing behavior:

```swift
init(projectID: UUID, sessionID: UUID, renderMode: SessionShelfRenderMode = .cards) { ... }
```

**Step 2: Replace `cardContainer` with a mode-aware surface**

Add a helper:

```swift
private func shelfSurface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: CodexDockTokens.surfaceCornerRadius,
                style: .continuous
            )
            .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: CodexDockTokens.surfaceCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(CodexDockTokens.surfaceBorderOpacity))
        )
}
```

Then:
- keep `.cards` using the existing card styling (if still needed elsewhere)
- for `.dock` use `shelfSurface` and remove the internal `.padding(.horizontal, 12)` so the dock controls horizontal inset.

**Step 3: Update each card function to use the new surface in dock mode**

Example change:
- `diffCard(...)` uses `shelfSurface { ... }` in dock mode
- same for queue/terminals/run/plan/approvals

**Step 4: Build**

Run: `swift test`

Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Session/SessionShelfView.swift
git commit -m "ui(ios): add dock render mode for session shelf"
```

---

## Task 4: Redo iOS `.chatGPT` Composer Layout To Match Codex

**Files:**
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift`

**Step 1: Remove the external plus button layout**

In `chatComposer`, replace the outer `HStack(alignment: .bottom, spacing: 12)` that currently renders `plusMenuButton` outside the rounded surface.

Target structure:
- the rounded surface contains:
  - attachments preview (optional)
  - status chip (optional)
  - multiline input
  - toolbar row (contains `+`, model menu, thinking menu, mic, primary action)

**Step 2: Add a Codex toolbar row (inside the surface)**

Add a helper view inside `InlineComposerView`:

```swift
private var codexToolbarRow: some View {
    HStack(spacing: 12) {
        plusToolbarButton

        modelMenu
        thinkingMenu

        Spacer(minLength: 0)

        if showsVoiceButton {
            voiceButton
        }

        submitButton
    }
    .padding(.top, 2)
}
```

Implement `plusToolbarButton` (plain glyph, not a floating circle):

```swift
private var plusToolbarButton: some View {
    Button { showsPlusMenu = true } label: {
        Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("composer.plus")
    .popover(isPresented: $showsPlusMenu, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
        plusMenuContent
    }
}
```

Extract `voiceButton` and `submitButton` from existing inline code so they can be reused cleanly.

**Step 3: Move model/thinking chips to the toolbar row**

Adjust `modelMenu` / `thinkingMenu` label style to match Codex:
- no capsule backgrounds
- inline text + chevron
- `.font(.subheadline.weight(.semibold))`

If you still want a visual chip, keep it extremely subtle (Codex uses mostly text).

**Step 4: Keep the footer row outside the surface**

Keep the permission/context row as-is (outside the surface), but ensure the composer view itself does not add its own `.padding(.horizontal, 12)`; the dock owns horizontal inset.

**Step 5: Build**

Run: `swift test`

Expected: PASS.

**Step 6: Manual check (Simulator)**

- `+` appears inside the composer toolbar row.
- Model + thinking appear on the same toolbar row as `+`.
- Attachments preview stays above input area.
- Stop/Send/Update button still works.

**Step 7: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/InlineComposerView.swift
git commit -m "ui(ios): match codex composer toolbar with internal plus"
```

---

## Task 5: Wire `CodexDockView` Into `SessionChatView` (iOS)

**Files:**
- Modify: `Sources/LabOSApp/Views/Session/SessionChatView.swift`

**Step 1: Replace the current bottom `safeAreaInset` content**

Current structure:
- `VStack(spacing: 8) { SessionShelfView(...); sessionComposer }`

Replace with:

```swift
.safeAreaInset(edge: .bottom, spacing: 0) {
    CodexDockView(
        shelf: {
            SessionShelfView(projectID: projectID, sessionID: sessionID, renderMode: .dock)
        },
        composer: {
            sessionComposerSurfaceOnly // see Step 2
        },
        footer: {
            sessionComposerFooterRow // permission + context ring
        }
    )
}
```

**Step 2: Split `sessionComposer` into surface + footer if needed**

If `InlineComposerView` still produces both surface + footer internally, keep `composer:` as `sessionComposer` and set `footer:` to `EmptyView()`.

Preferred (matches the dock concept):
- `sessionComposerSurfaceOnly` is only the rounded composer surface.
- `sessionComposerFooterRow` is the permission/context row outside.

**Step 3: Build**

Run: `swift test`

Expected: PASS.

**Step 4: Manual check**

- Shelf rows appear directly above composer with tight spacing.
- Footer row is outside dock surfaces.
- Keyboard behavior is stable.

**Step 5: Commit**

```bash
git add Sources/LabOSApp/Views/Session/SessionChatView.swift
git commit -m "ui(ios): use codex dock layout in session chat view"
```

---

## Task 6: Wire `CodexDockView` Into `ProjectPageView` (iOS)

**Files:**
- Modify: `Sources/LabOSApp/Views/Project/ProjectPageView.swift`
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift` (if composer/footer split is required)

**Step 1: Replace overlay composer + height preference with a bottom safe area inset**

Today `ProjectPageView` uses:
- `overlay(alignment: .bottom) { projectComposer }`
- `safeAreaInset(edge: .bottom) { Color.clear.frame(height: composerHeight + 8) }`
- geometry preference to measure composer height

Change to:

```swift
.safeAreaInset(edge: .bottom, spacing: 0) {
    CodexDockView(
        shelf: { EmptyView() },
        composer: { projectComposerSurfaceOnly },
        footer: { projectComposerFooterRow }
    )
}
```

Then delete the overlay, the spacer inset, and the preference measurement glue.

**Step 2: Build**

Run: `swift test`

Expected: PASS.

**Step 3: Manual check**

- Project composer looks identical to session composer.
- Footer row remains outside dock surfaces.
- List scrolling stays above the dock without manual height measurement.

**Step 4: Commit**

```bash
git add Sources/LabOSApp/Views/Project/ProjectPageView.swift
git commit -m "ui(ios): use codex dock layout on project page"
```

---

## Task 7: Cleanup + Final Verification

**Files:**
- Modify: `Sources/LabOSApp/Views/Shared/InlineComposerView.swift` (remove unused preference keys / legacy layout helpers)

**Step 1: Remove unused `ComposerHeightPreferenceKey` if no longer referenced**

Confirm with:

```bash
rg -n "ComposerHeightPreferenceKey" Sources/LabOSApp
```

If only defined but unused, delete it.

**Step 2: Run full verification**

Run:
- `swift test`

Expected: PASS.

**Step 3: Manual acceptance checklist**

- iOS session: shelf + composer closely stacked, `+` inside composer.
- iOS project: same composer as session, no shelf.
- Footer row remains outside dock surfaces.
- Stop/queue/steer still works during streaming.

**Step 4: Commit**

```bash
git add Sources/LabOSApp/Views/Shared/InlineComposerView.swift
git commit -m "ui(ios): cleanup composer layout after codex dock refactor"
```

---

## Execution Notes

- This plan intentionally avoids adding new UI snapshot dependencies.
- If the visual match is still slightly off after implementation, tune only in `CodexDockTokens.swift` first.

