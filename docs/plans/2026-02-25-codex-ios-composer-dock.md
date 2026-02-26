# Revised iOS Codex Dock Plan: Unified Shelf + Composer + Footer (Zero-Gap, Codex-Matched)

## Summary

This replaces the current dock plan with a stricter Codex-style structure: one continuous bottom dock surface on iOS with zero vertical gaps between shelf rows, composer, and footer. Internal section boundaries are handled by subtle 1px dividers, not spacing. The previous rule “footer outside dock” is removed and replaced with “footer inside unified dock.”

## Public API / Interface Changes

1. Add shared dock tokens in `Sources/LabOSApp/Views/Shared/CodexDockTokens.swift`.
   Public constants:
   - `horizontalInset = 12`
   - `outerCornerRadius = 22`
   - `sectionSpacing = 0`
   - `dividerOpacity = 0.10`
   - `dividerHorizontalInset = 12`
   - `borderOpacity = 0.10`
   - `shadowOpacity = 0.08`
   - `shadowRadius = 12`
   - `shadowYOffset = 2`
   - `scrimOpacity(dark: 0.98, light: 0.92)`

2. Implement `Sources/LabOSApp/Views/Shared/CodexDockView.swift` as a unified container with explicit section visibility flags.
   Required init contract:
   - `init(showsShelf: Bool, showsFooter: Bool, shelf: () -> Shelf, composer: () -> Composer, footer: () -> Footer)`

3. Update `Sources/LabOSApp/Views/Session/SessionShelfView.swift` render mode contract.
   - `SessionShelfRenderMode.cards` keeps existing card behavior.
   - `SessionShelfRenderMode.dock` renders flush rows with no card chrome and no row spacing.

4. Update `Sources/LabOSApp/Views/Shared/InlineComposerView.swift` with explicit chrome mode.
   - Add `chatComposerChrome: .standalone | .embeddedInDock` (default `.standalone`).
   - `.embeddedInDock` removes outer dock-like background/padding so parent dock owns chrome.

## Implementation Steps

1. Replace existing plan constraints with unified-surface, divider-first, zero-gap behavior while keeping iOS-only scope.

2. Build unified dock container.
   - `VStack(spacing: 0)` section stack.
   - Divider only between consecutive visible sections.
   - One shared rounded background/border/shadow for the full dock.
   - External horizontal inset via dock tokens.

3. Refactor shelf into dock rows.
   - Keep existing behavior for `.cards`.
   - For `.dock`, remove row card backgrounds/strokes/shadows.
   - Keep per-row content padding.
   - Add subtle dividers between rows.
   - Remove root horizontal padding in dock mode.

4. Refactor composer for embedded dock mode.
   - Keep Codex toolbar structure: `+`, model, thinking, optional mic, submit.
   - Set `+` button to plain 30x30 glyph style.
   - Use text-forward model/thinking labels.
   - In `.embeddedInDock`, remove outer scrim/padding.
   - Keep permission/context footer in the same composer section with zero spacing and a divider.

5. Integrate session page dock.
   - Replace current bottom stack with `CodexDockView`.
   - Pass shelf in `.dock` mode.
   - Use embedded composer chrome.

6. Integrate project page dock.
   - Replace overlay + `ComposerHeightPreferenceKey` spacer flow with `safeAreaInset(edge: .bottom, spacing: 0)` and `CodexDockView`.
   - Remove overlay/preference glue once no longer needed.

7. Cleanup.
   - Remove `ComposerHeightPreferenceKey` if unused.
   - Keep accessibility IDs stable: `composer.plus`, `composer.model.menu`, `composer.thinking.menu`, `composer.input`, `composer.send`.

## Test Cases and Scenarios

1. Run `swift test`.
2. Session page, 0 shelf rows: composer + footer still render as one continuous dock block.
3. Session page, 1 shelf row: row touches composer with divider-only separation and no gap.
4. Session page, multiple shelf rows: tightly stacked rows, no card gaps, subtle dividers.
5. Project page: composer and footer match session dock style without shelf.
6. Streaming/editing states: stop/send/update behavior unchanged.
7. Keyboard interactions: dock remains anchored without jumpy inset artifacts.

## Assumptions and Defaults

1. Platform scope stays iOS-only.
2. “Follow Codex UI exactly” means structural parity first: unified surface + divider rhythm + zero internal gaps.
3. Footer is included in the no-gap unified dock module.
4. Subtle separators are required between shelf rows and major sections.
5. Visual tuning should happen in `CodexDockTokens` only, not ad hoc spacing overrides across feature views.
