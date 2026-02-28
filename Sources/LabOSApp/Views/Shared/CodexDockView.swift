#if os(iOS)
import SwiftUI

struct CodexDockView<Shelf: View, Composer: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let showsShelf: Bool
    private let showsFooter: Bool
    private let shelf: Shelf
    private let composer: Composer
    private let footer: Footer

    init(
        showsShelf: Bool,
        showsFooter: Bool,
        @ViewBuilder shelf: () -> Shelf,
        @ViewBuilder composer: () -> Composer,
        @ViewBuilder footer: () -> Footer
    ) {
        self.showsShelf = showsShelf
        self.showsFooter = showsFooter
        self.shelf = shelf()
        self.composer = composer()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CodexDockTokens.sectionSpacing) {
            if showsShelf {
                shelf
                dockDivider
            }

            composer

            if showsFooter {
                dockDivider
                footer
            }
        }
        .background(dockSurfaceBackground)
        .overlay(dockSurfaceStroke)
        .clipShape(
            RoundedRectangle(cornerRadius: CodexDockTokens.outerCornerRadius, style: .continuous)
        )
        .shadow(
            color: Color.black.opacity(CodexDockTokens.shadowOpacity),
            radius: CodexDockTokens.shadowRadius,
            x: 0,
            y: CodexDockTokens.shadowYOffset
        )
        .padding(.horizontal, CodexDockTokens.horizontalInset)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(
            Color(.systemBackground)
                .opacity(CodexDockTokens.scrimOpacity(colorScheme))
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(CodexDockTokens.dividerOpacity))
            .frame(height: CodexDockTokens.dividerThickness)
            .padding(.horizontal, CodexDockTokens.dividerHorizontalInset)
    }

    private var dockSurfaceBackground: some View {
        RoundedRectangle(cornerRadius: CodexDockTokens.outerCornerRadius, style: .continuous)
            .fill(Color(.secondarySystemBackground))
    }

    private var dockSurfaceStroke: some View {
        RoundedRectangle(cornerRadius: CodexDockTokens.outerCornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(CodexDockTokens.borderOpacity))
    }
}
#endif
