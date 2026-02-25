import MarkdownUI
import SwiftUI

extension Theme {
    static var labOS: Theme {
        Theme.gitHub
            .text {
                ForegroundColor(.primary)
                BackgroundColor(nil)
                FontSize(16)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(.primary)
                BackgroundColor(Color.primary.opacity(0.14))
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.22))
                        .frame(width: 3)
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .codeBlock { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14))
                )
            }
    }
}
