#if os(iOS)
import MarkdownUI
import SwiftUI
import UIKit
import XCTest
@testable import LabOSApp

@MainActor
final class MarkdownThemeTests: XCTestCase {
    func testLabOSThemeRemovesProseBackgroundColor() {
        XCTAssertNil(Theme.labOS.textBackgroundColor)
    }

    func testLabOSThemeCanRenderInLightAndDarkColorSchemes() {
        let markdown = """
        # Title

        Paragraph with `inline code`.

        > quoted line

        ```swift
        print(\"hello\")
        ```
        """

        let light = UIHostingController(
            rootView: Markdown(markdown)
                .markdownTheme(.labOS)
                .environment(\.colorScheme, .light)
        )
        light.loadViewIfNeeded()
        light.view.setNeedsLayout()
        light.view.layoutIfNeeded()

        let dark = UIHostingController(
            rootView: Markdown(markdown)
                .markdownTheme(.labOS)
                .environment(\.colorScheme, .dark)
        )
        dark.loadViewIfNeeded()
        dark.view.setNeedsLayout()
        dark.view.layoutIfNeeded()

        XCTAssertNotNil(light.view)
        XCTAssertNotNil(dark.view)
    }
}
#endif
