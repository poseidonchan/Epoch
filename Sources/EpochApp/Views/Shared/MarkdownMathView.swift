#if os(iOS)
import EpochCore
import MarkdownUI
import SwiftUI
import UIKit
import WebKit

struct MarkdownMathView: View {
    let markdown: String
    var onImageTap: ((URL) -> Void)? = nil
    var resolveImageURL: ((URL) -> URL?)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 20
    @State private var webContentReady = false
    @State private var cachedHeight: CGFloat?
    @State private var cachedSnapshot: UIImage?

    private var normalizedMarkdown: String {
        MarkdownDisplayNormalizer.normalize(markdown)
    }

    private var preparedMarkdown: String {
        let prepared = MarkdownMathPreprocessor.prepareForRendering(normalizedMarkdown)
        return Self.rewriteImageURLs(in: prepared, resolveImageURL: resolveImageURL)
    }

    private var renderSignature: String {
        MarkdownMathWebView.renderSignature(markdown: preparedMarkdown, colorScheme: colorScheme)
    }

    private var likelyMath: Bool {
        MarkdownMathPreprocessor.likelyContainsMath(normalizedMarkdown)
    }

    private var shouldUseSnapshotFallback: Bool {
        normalizedMarkdown.contains("\\(")
            || normalizedMarkdown.contains("\\[")
            || normalizedMarkdown.contains("$$")
            || normalizedMarkdown.contains("\\begin{")
    }

    private var displayHeight: CGFloat {
        if webContentReady {
            return max(20, webHeight)
        }
        if let cachedHeight {
            return max(20, cachedHeight)
        }
        return max(20, webHeight)
    }

    var body: some View {
        if MarkdownMathWebView.canRender {
            ZStack(alignment: .topLeading) {
                if !webContentReady {
                    if shouldUseSnapshotFallback, let cachedSnapshot {
                        Image(uiImage: cachedSnapshot)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: displayHeight, alignment: .topLeading)
                            .clipped()
                    } else if !likelyMath {
                        fallbackMarkdown
                            .frame(height: displayHeight, alignment: .topLeading)
                    }
                }

                MarkdownMathWebView(
                    markdown: preparedMarkdown,
                    renderSignature: renderSignature,
                    captureSnapshots: shouldUseSnapshotFallback,
                    onImageTap: onImageTap,
                    resolveImageURL: resolveImageURL,
                    height: $webHeight,
                    isReady: $webContentReady
                )
                    .frame(height: displayHeight)
                    .opacity(webContentReady ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: webContentReady)
            .onAppear {
                loadCachedState(for: renderSignature)
            }
            .onChange(of: renderSignature) { _, newValue in
                webContentReady = false
                loadCachedState(for: newValue)
            }
        } else {
            fallbackMarkdown
        }
    }

    private var fallbackMarkdown: some View {
        Markdown(preparedMarkdown)
            .markdownTheme(.epoch)
            .markdownImageProvider(
                ChatMarkdownImageProvider(
                    onImageTap: onImageTap,
                    resolveImageURL: resolveImageURL
                )
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func rewriteImageURLs(
        in markdown: String,
        resolveImageURL: ((URL) -> URL?)?
    ) -> String {
        guard let resolveImageURL else { return markdown }
        let markdownRewritten = rewriteMarkdownImageDestinations(
            in: markdown,
            resolveImageURL: resolveImageURL
        )
        return rewriteHTMLImageSources(
            in: markdownRewritten,
            resolveImageURL: resolveImageURL
        )
    }

    private static func rewriteMarkdownImageDestinations(
        in markdown: String,
        resolveImageURL: @escaping (URL) -> URL?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"!\\[[^\\]]*\\]\\(([^)]+)\\)"#) else {
            return markdown
        }
        let source = markdown as NSString
        let mutable = NSMutableString(string: markdown)
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))

        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let destinationRange = match.range(at: 1)
            guard destinationRange.location != NSNotFound else { continue }
            let destination = source.substring(with: destinationRange)
            guard let rewritten = rewriteImageDestination(
                destination,
                resolveImageURL: resolveImageURL
            ) else {
                continue
            }
            mutable.replaceCharacters(in: destinationRange, with: rewritten)
        }

        return mutable as String
    }

    private static func rewriteImageDestination(
        _ destination: String,
        resolveImageURL: @escaping (URL) -> URL?
    ) -> String? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawURLToken: String
        let prefix: String
        let suffix: String
        if trimmed.hasPrefix("<"), let end = trimmed.firstIndex(of: ">") {
            rawURLToken = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            prefix = "<"
            suffix = ">" + String(trimmed[trimmed.index(after: end)...])
        } else if let whitespace = trimmed.firstIndex(where: { $0.isWhitespace }) {
            rawURLToken = String(trimmed[..<whitespace])
            prefix = ""
            suffix = String(trimmed[whitespace...])
        } else {
            rawURLToken = trimmed
            prefix = ""
            suffix = ""
        }

        guard let resolved = ChatImageURLResolver.resolve(rawURLToken) else {
            return nil
        }
        let overridden = resolveImageURL(resolved) ?? resolved
        let rewrittenToken = overridden.absoluteString
        guard rewrittenToken != rawURLToken else { return nil }
        return "\(prefix)\(rewrittenToken)\(suffix)"
    }

    private static func rewriteHTMLImageSources(
        in markdown: String,
        resolveImageURL: @escaping (URL) -> URL?
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<img\b([^>]*?)\bsrc\s*=\s*(['"])(.*?)\2"#,
            options: [.caseInsensitive]
        ) else {
            return markdown
        }
        let source = markdown as NSString
        let mutable = NSMutableString(string: markdown)
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))

        for match in matches.reversed() {
            guard match.numberOfRanges > 3 else { continue }
            let srcRange = match.range(at: 3)
            guard srcRange.location != NSNotFound else { continue }
            let rawURL = source.substring(with: srcRange)
            guard let resolved = ChatImageURLResolver.resolve(rawURL) else { continue }
            let overridden = resolveImageURL(resolved) ?? resolved
            let rewritten = overridden.absoluteString
            guard rewritten != rawURL else { continue }
            mutable.replaceCharacters(in: srcRange, with: rewritten)
        }

        return mutable as String
    }

    private func loadCachedState(for key: String) {
        guard let cached = MarkdownMathRenderCache.entry(for: key) else {
            cachedHeight = nil
            cachedSnapshot = nil
            return
        }
        cachedHeight = cached.height
        cachedSnapshot = cached.snapshot
        if !webContentReady {
            webHeight = max(20, cached.height)
        }
    }
}

private struct MarkdownMathWebView: UIViewRepresentable {
    let markdown: String
    let renderSignature: String
    let captureSnapshots: Bool
    let onImageTap: ((URL) -> Void)?
    let resolveImageURL: ((URL) -> URL?)?
    @Binding var height: CGFloat
    @Binding var isReady: Bool

    @Environment(\.colorScheme) private var colorScheme

    static var canRender: Bool {
        assetURLs(bundle: resourceBundle) != nil
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "height")
        userContentController.add(context.coordinator, name: "imageTap")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let urls = Self.assetURLs(bundle: Self.resourceBundle) else { return }
        context.coordinator.onImageTap = onImageTap
        context.coordinator.resolveImageURL = resolveImageURL

        let prepared = markdown
        if context.coordinator.lastSignature == renderSignature {
            if let cached = MarkdownMathRenderCache.entry(for: renderSignature) {
                let nextHeight = max(20, cached.height)
                if abs(height - nextHeight) > 1 {
                    DispatchQueue.main.async { height = nextHeight }
                }
            }
            if !isReady {
                DispatchQueue.main.async { isReady = true }
            }
            return
        }
        context.coordinator.lastSignature = renderSignature
        context.coordinator.cacheKey = renderSignature
        context.coordinator.snapshotEnabled = captureSnapshots
        context.coordinator.snapshotCapturedForKey = nil
        context.coordinator.webView = uiView

        if let cached = MarkdownMathRenderCache.entry(for: renderSignature) {
            let nextHeight = max(20, cached.height)
            if abs(height - nextHeight) > 1 {
                DispatchQueue.main.async { height = nextHeight }
            }
        } else {
            DispatchQueue.main.async { height = 20 }
        }
        DispatchQueue.main.async { isReady = false }

        let escaped = Self.escapeHTML(prepared)
        let highlightCSS = (colorScheme == .dark ? urls.highlightDarkCSS : urls.highlightLightCSS)?.absoluteString ?? ""
        let highlightLinkHTML = highlightCSS.isEmpty ? "" : "<link rel=\"stylesheet\" href=\"\(highlightCSS)\">"
        let highlightScriptsHTML = [
            urls.highlightScript,
            urls.highlightPythonScript,
            urls.highlightRScript,
        ]
        .compactMap { $0?.absoluteString }
        .map { "<script src=\"\($0)\"></script>" }
        .joined(separator: "\n")

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              :root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); }
              body {
                margin: 0;
                padding: 0;
                background: transparent;
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
                font-size: 16px;
                line-height: 1.45;
                color: \(colorScheme == .dark ? "#FFFFFF" : "#111111");
              }
              #content {
                padding: 0;
                word-wrap: break-word;
                overflow-wrap: anywhere;
              }
              h1,h2,h3,h4 { margin: 0.75em 0 0.4em; }
              p { margin: 0.55em 0; }
              ul,ol { margin: 0.55em 0 0.55em 1.2em; padding: 0; }
              li { margin: 0.25em 0; }
              blockquote {
                margin: 0.6em 0;
                padding: 0.15em 0 0.15em 0.9em;
                border-left: 3px solid rgba(120,120,120,0.35);
                color: rgba(127,127,127,0.95);
              }
              pre {
                margin: 0.7em 0;
                padding: 12px;
                overflow: auto;
                white-space: pre;
                word-break: normal;
                overflow-wrap: normal;
                border-radius: 12px;
                background: rgba(127,127,127,\(colorScheme == .dark ? "0.16" : "0.10"));
                border: 1px solid rgba(127,127,127,\(colorScheme == .dark ? "0.18" : "0.14"));
              }
              code {
                font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
                font-size: 0.92em;
              }
              :not(pre) > code {
                padding: 0.16em 0.33em;
                border-radius: 6px;
                background: rgba(127,127,127,\(colorScheme == .dark ? "0.18" : "0.12"));
              }
              table { border-collapse: collapse; margin: 0.75em 0; width: 100%; }
              th, td { border: 1px solid rgba(127,127,127,\(colorScheme == .dark ? "0.28" : "0.22")); padding: 6px 8px; }
              img { max-width: 100%; height: auto; }
              .math-display {
                display: block;
                width: 100%;
                margin: 0.7em 0;
                overflow-x: auto;
                overflow-y: hidden;
                -webkit-overflow-scrolling: touch;
                text-align: center;
              }
              .math-display .katex-display {
                margin: 0 !important;
                display: inline-block !important;
                min-width: max-content;
              }
              .katex-display {
                margin: 0.7em 0;
                overflow-x: auto;
                overflow-y: hidden;
                -webkit-overflow-scrolling: touch;
                text-align: center;
              }
              .katex-display > .katex {
                display: inline-block;
                min-width: max-content;
              }
              .md-error { white-space: pre-wrap; }
            </style>
            <link rel="stylesheet" href="\(urls.katexCSS.absoluteString)">
            \(highlightLinkHTML)
            \(highlightScriptsHTML)
            <script src="\(urls.markdownItScript.absoluteString)"></script>
            <script src="\(urls.katexScript.absoluteString)"></script>
            <script src="\(urls.autoRenderScript.absoluteString)"></script>
            <script src="\(urls.rendererScript.absoluteString)"></script>
          </head>
          <body>
            <pre id="md-source" style="display:none">\(escaped)</pre>
            <div id="content"></div>
          </body>
        </html>
        """

        uiView.loadHTMLString(html, baseURL: urls.baseURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            height: $height,
            isReady: $isReady,
            onImageTap: onImageTap,
            resolveImageURL: resolveImageURL
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var isReady: Binding<Bool>
        var onImageTap: ((URL) -> Void)?
        var resolveImageURL: ((URL) -> URL?)?
        var lastSignature: String?
        var cacheKey: String?
        var snapshotEnabled = true
        var snapshotCapturedForKey: String?
        weak var webView: WKWebView?

        init(
            height: Binding<CGFloat>,
            isReady: Binding<Bool>,
            onImageTap: ((URL) -> Void)?,
            resolveImageURL: ((URL) -> URL?)?
        ) {
            self.height = height
            self.isReady = isReady
            self.onImageTap = onImageTap
            self.resolveImageURL = resolveImageURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            updateHeight(webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.updateHeight(webView)
                self?.captureSnapshotIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.updateHeight(webView)
                self?.captureSnapshotIfNeeded()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "imageTap" {
                guard let rawURL = message.body as? String,
                      let resolved = ChatImageURLResolver.resolve(rawURL) else {
                    return
                }
                let overridden = resolveImageURL?(resolved) ?? resolved
                onImageTap?(overridden)
                return
            }
            guard message.name == "height" else { return }

            let value: Double?
            if let number = message.body as? Double {
                value = number
            } else if let number = message.body as? NSNumber {
                value = number.doubleValue
            } else if let string = message.body as? String {
                value = Double(string)
            } else {
                value = nil
            }

            guard let value else { return }
            let next = CGFloat(value)
            if abs(height.wrappedValue - next) > 1 {
                height.wrappedValue = next
            }
            cacheHeight(next)
            isReady.wrappedValue = true
            captureSnapshotIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                return
            }
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func updateHeight(_ webView: WKWebView) {
            let js = """
            (() => {
              const el = document.getElementById('content');
              if (!el) {
                return Math.max(document.body.scrollHeight, document.documentElement.scrollHeight);
              }
              const rect = el.getBoundingClientRect();
              const height = Math.max(el.scrollHeight, rect ? rect.height : 0);
              return Math.ceil(height + 4);
            })()
            """

            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                if let number = result as? Double {
                    let next = CGFloat(number)
                    if abs(self.height.wrappedValue - next) > 1 {
                        self.height.wrappedValue = next
                    }
                    self.cacheHeight(next)
                    isReady.wrappedValue = true
                } else {
                    // If we can't measure for some reason, at least show the web content.
                    isReady.wrappedValue = true
                }
            }
        }

        private func cacheHeight(_ value: CGFloat) {
            guard let cacheKey else { return }
            MarkdownMathRenderCache.updateHeight(max(20, value), for: cacheKey)
        }

        private func captureSnapshotIfNeeded() {
            guard snapshotEnabled else { return }
            guard let webView, let cacheKey else { return }
            guard snapshotCapturedForKey != cacheKey else { return }

            let width = webView.bounds.width
            let height = self.height.wrappedValue
            guard width > 10, height > 10, height <= 2200 else { return }

            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            webView.takeSnapshot(with: config) { image, _ in
                guard let image else { return }
                Task { @MainActor in
                    MarkdownMathRenderCache.updateSnapshot(image, for: cacheKey)
                }
            }
            snapshotCapturedForKey = cacheKey
        }
    }

    static func renderSignature(markdown: String, colorScheme: ColorScheme) -> String {
        "\(colorScheme == .dark ? "dark" : "light")::\(markdown)"
    }

    private struct AssetURLs: Sendable {
        var baseURL: URL
        var markdownItScript: URL
        var rendererScript: URL
        var katexScript: URL
        var katexCSS: URL
        var autoRenderScript: URL
        var highlightScript: URL?
        var highlightPythonScript: URL?
        var highlightRScript: URL?
        var highlightLightCSS: URL?
        var highlightDarkCSS: URL?
    }

    private static var resourceBundle: Bundle {
#if SWIFT_PACKAGE
        return Bundle.module
#else
        return Bundle.main
#endif
    }

    private static func assetURLs(bundle: Bundle) -> AssetURLs? {
        func firstURL(_ name: String, _ ext: String, _ subdirs: [String?]) -> URL? {
            for sub in subdirs {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: sub) {
                    return url
                }
            }
            return nil
        }

        let markdownSubdirs: [String?] = ["Resources/markdown", "markdown", "Resources", nil]
        let katexSubdirs: [String?] = ["Resources/katex", "katex", "Resources", nil]
        let highlightSubdirs: [String?] = ["Resources/highlightjs", "highlightjs", "Resources", nil]

        guard let markdownIt = firstURL("markdown-it.min", "js", markdownSubdirs),
              let renderer = firstURL("markdown-math-renderer", "js", markdownSubdirs),
              let katexJS = firstURL("katex.min", "js", katexSubdirs),
              let katexCSS = firstURL("katex.min", "css", katexSubdirs),
              let autoRender = firstURL("auto-render.min", "js", katexSubdirs)
        else {
            return nil
        }

        let highlight = firstURL("highlight.min", "js", highlightSubdirs)
        let python = firstURL("python.min", "js", ["Resources/highlightjs/languages", "highlightjs/languages", "Resources", nil])
        let r = firstURL("r.min", "js", ["Resources/highlightjs/languages", "highlightjs/languages", "Resources", nil])
        let cssLight = firstURL("github.min", "css", ["Resources/highlightjs/styles", "highlightjs/styles", "Resources", nil])
        let cssDark = firstURL("github-dark.min", "css", ["Resources/highlightjs/styles", "highlightjs/styles", "Resources", nil])

        return AssetURLs(
            baseURL: bundle.bundleURL,
            markdownItScript: markdownIt,
            rendererScript: renderer,
            katexScript: katexJS,
            katexCSS: katexCSS,
            autoRenderScript: autoRender,
            highlightScript: highlight,
            highlightPythonScript: python,
            highlightRScript: r,
            highlightLightCSS: cssLight,
            highlightDarkCSS: cssDark
        )
    }

    private static func escapeHTML(_ input: String) -> String {
        var s = input
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\"", with: "&quot;")
        s = s.replacingOccurrences(of: "'", with: "&#39;")
        return s
    }
}

private enum MarkdownMathRenderCache {
    struct Entry {
        var height: CGFloat
        var snapshot: UIImage?
        var timestamp: TimeInterval
    }

    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let maxEntries = 96

    static func entry(for key: String) -> Entry? {
        entries[key]
    }

    static func updateHeight(_ height: CGFloat, for key: String) {
        let time = Date().timeIntervalSince1970
        var next = entries[key] ?? Entry(height: max(20, height), snapshot: nil, timestamp: time)
        next.height = max(20, height)
        next.timestamp = time
        entries[key] = next
        trimIfNeeded()
    }

    static func updateSnapshot(_ snapshot: UIImage, for key: String) {
        let time = Date().timeIntervalSince1970
        var next = entries[key] ?? Entry(height: 20, snapshot: nil, timestamp: time)
        next.snapshot = snapshot
        next.timestamp = time
        entries[key] = next
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        guard entries.count > maxEntries else { return }
        let overflow = entries.count - maxEntries
        let oldest = entries.sorted { $0.value.timestamp < $1.value.timestamp }.prefix(overflow)
        for (key, _) in oldest {
            entries.removeValue(forKey: key)
        }
    }
}
#endif
