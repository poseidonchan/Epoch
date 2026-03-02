#if os(iOS)
import SwiftUI
import UIKit

struct ChatImagePreviewRequest: Identifiable {
    let id = UUID()
    let imageURLs: [URL]
    let initialIndex: Int
    let allowsPaging: Bool

    init(imageURLs: [URL], initialIndex: Int, allowsPaging: Bool) {
        self.imageURLs = imageURLs
        if imageURLs.isEmpty {
            self.initialIndex = 0
        } else {
            self.initialIndex = min(max(0, initialIndex), imageURLs.count - 1)
        }
        self.allowsPaging = allowsPaging && imageURLs.count > 1
    }
}

struct ChatImageLightboxView: View {
    let request: ChatImagePreviewRequest
    let onClose: () -> Void

    @State private var selectedIndex: Int
    @State private var shareSheetPayload: ShareSheetPayload?
    @State private var saveErrorMessage: String?
    @State private var preparingShare = false

    init(request: ChatImagePreviewRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _selectedIndex = State(initialValue: request.initialIndex)
    }

    private var pagingEnabled: Bool {
        request.allowsPaging && request.imageURLs.count > 1
    }

    private var currentImageURL: URL? {
        guard request.imageURLs.indices.contains(selectedIndex) else { return nil }
        return request.imageURLs[selectedIndex]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if request.imageURLs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Image unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if pagingEnabled {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(request.imageURLs.enumerated()), id: \.offset) { index, url in
                        ChatLightboxImagePage(url: url)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            } else {
                ChatLightboxImagePage(url: request.imageURLs[selectedIndex])
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.55))
                    )
            }
            .padding(.top, 12)
            .padding(.leading, 12)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                saveCurrentImage()
            } label: {
                if preparingShare {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    Label("Save", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .disabled(preparingShare || currentImageURL == nil)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
            )
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .overlay(alignment: .top) {
            if pagingEnabled {
                Text("\(selectedIndex + 1)/\(request.imageURLs.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.55))
                    )
                    .padding(.top, 14)
            }
        }
        .sheet(item: $shareSheetPayload) { payload in
            ActivityShareSheet(items: payload.items)
        }
        .alert("Couldn’t save image", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "Unknown error")
        }
        .statusBarHidden()
    }

    private func saveCurrentImage() {
        guard !preparingShare else { return }
        guard let url = currentImageURL else { return }

        preparingShare = true
        Task {
            do {
                let item = try await makeShareItem(from: url)
                await MainActor.run {
                    shareSheetPayload = ShareSheetPayload(items: [item])
                }
            } catch {
                await MainActor.run {
                    saveErrorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                preparingShare = false
            }
        }
    }

    private func makeShareItem(from url: URL) async throws -> Any {
        if url.isFileURL {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw NSError(
                    domain: "Epoch",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "The image file no longer exists."]
                )
            }
            return url
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard UIImage(data: data) != nil else {
            throw NSError(
                domain: "Epoch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded data is not a valid image."]
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("epoch-chat-share", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let fileURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}

private struct ShareSheetPayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ChatLightboxImagePage: View {
    let url: URL

    @State private var loadState: LoadState = .loading
    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var imageOffset: CGSize = .zero
    @State private var lastImageOffset: CGSize = .zero

    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                switch loadState {
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                case let .loaded(image):
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(zoomScale)
                        .offset(imageOffset)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        zoomScale = min(max(1, lastZoomScale * value), 5)
                                    }
                                    .onEnded { _ in
                                        lastZoomScale = zoomScale
                                        if zoomScale <= 1 {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                imageOffset = .zero
                                                lastImageOffset = .zero
                                            }
                                        }
                                    },
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard zoomScale > 1 else { return }
                                        imageOffset = CGSize(
                                            width: lastImageOffset.width + value.translation.width,
                                            height: lastImageOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in
                                        if zoomScale > 1 {
                                            lastImageOffset = imageOffset
                                        } else {
                                            lastImageOffset = .zero
                                        }
                                    }
                            )
                        )
                case .failed:
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Couldn’t load image")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(20)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: url.absoluteString) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        loadState = .loading
        zoomScale = 1
        lastZoomScale = 1
        imageOffset = .zero
        lastImageOffset = .zero

        if url.isFileURL {
            if let image = UIImage(contentsOfFile: url.path) {
                loadState = .loaded(image)
            } else {
                loadState = .failed
            }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else {
                loadState = .failed
                return
            }
            loadState = .loaded(image)
        } catch {
            loadState = .failed
        }
    }
}
#endif
