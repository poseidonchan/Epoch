#if os(iOS)
import SwiftUI
import UIKit

enum CodexDockTokens {
    static let horizontalInset: CGFloat = 12
    static let outerCornerRadius: CGFloat = 22
    static let sectionSpacing: CGFloat = 0
    static let dividerOpacity: Double = 0.10
    static let dividerHorizontalInset: CGFloat = 12
    static let dividerThickness: CGFloat = 0.5
    static let borderOpacity: Double = 0.10
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 12
    static let shadowYOffset: CGFloat = 2

    static func scrimOpacity(_ scheme: ColorScheme) -> Double {
        scheme == .dark ? 0.98 : 0.92
    }
}
#endif
