#if os(iOS)
import MarkdownUI
import SwiftUI
import UIKit

struct ChatMarkdownImageProvider: @MainActor ImageProvider {
    var onImageTap: ((URL) -> Void)?
    var resolveImageURL: ((URL) -> URL?)?

    @MainActor
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        ChatMarkdownImageView(
            url: url,
            onImageTap: onImageTap,
            resolveImageURL: resolveImageURL
        )
    }
}

private struct ChatMarkdownImageView: View {
    let url: URL?
    let onImageTap: ((URL) -> Void)?
    let resolveImageURL: ((URL) -> URL?)?

    var body: some View {
        Group {
            if let resolvedURL {
                imageBody(for: resolvedURL)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onImageTap?(resolvedURL)
                    }
            } else {
                imagePlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resolvedURL: URL? {
        guard let url else { return nil }
        return resolveImageURL?(url) ?? url
    }

    @ViewBuilder
    private func imageBody(for url: URL) -> some View {
        if url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                imagePlaceholder
            }
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    imagePlaceholder
                case .empty:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                @unknown default:
                    imagePlaceholder
                }
            }
        }
    }

    private var imagePlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .overlay(
                Image(systemName: "photo")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            )
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
    }
}
#endif
