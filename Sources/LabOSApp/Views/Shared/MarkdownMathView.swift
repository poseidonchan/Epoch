#if os(iOS)
import LabOSCore
import MarkdownUI
import SwiftUI
import WebKit

struct MarkdownMathView: View {
    let markdown: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 20
    @State private var webContentReady = false

    private var normalizedMarkdown: String {
        MarkdownDisplayNormalizer.normalize(markdown)
    }

    var body: some View {
        if MarkdownMathWebView.canRender {
            ZStack(alignment: .topLeading) {
                fallbackMarkdown
                    .opacity(webContentReady ? 0 : 1)
                    .frame(height: webContentReady ? 0 : nil, alignment: .top)
                    .clipped()

                MarkdownMathWebView(markdown: normalizedMarkdown, height: $webHeight, isReady: $webContentReady)
                    .frame(height: max(20, webHeight))
                    .opacity(webContentReady ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.16), value: webContentReady)
            .onChange(of: normalizedMarkdown) { _, _ in
                webContentReady = false
            }
            .onChange(of: colorScheme) { _, _ in
                webContentReady = false
            }
        } else {
            fallbackMarkdown
        }
    }

    private var fallbackMarkdown: some View {
        Markdown(MarkdownMathPreprocessor.prepareForRendering(normalizedMarkdown))
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(.primary)
                BackgroundColor(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .padding(12)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                )
            }
            .textSelection(.enabled)
    }
}

private struct MarkdownMathWebView: UIViewRepresentable {
    let markdown: String
    @Binding var height: CGFloat
    @Binding var isReady: Bool

    @Environment(\.colorScheme) private var colorScheme

    static var canRender: Bool {
        assetURLs(bundle: resourceBundle) != nil
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "height")

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

        let prepared = MarkdownMathPreprocessor.prepareForRendering(markdown)
        let signature = "\(colorScheme == .dark ? "dark" : "light")::\(prepared)"
        if context.coordinator.lastSignature == signature {
            return
        }
        context.coordinator.lastSignature = signature
        isReady = false
        height = 20

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
        Coordinator(height: $height, isReady: $isReady)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<CGFloat>
        var isReady: Binding<Bool>
        var lastSignature: String?

        init(height: Binding<CGFloat>, isReady: Binding<Bool>) {
            self.height = height
            self.isReady = isReady
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            updateHeight(webView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.updateHeight(webView)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.updateHeight(webView)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
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
            isReady.wrappedValue = true
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
                    isReady.wrappedValue = true
                } else {
                    // If we can't measure for some reason, at least show the web content.
                    isReady.wrappedValue = true
                }
            }
        }
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
#endif
