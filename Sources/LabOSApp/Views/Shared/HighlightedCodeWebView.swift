#if os(iOS)
import SwiftUI
import WebKit

struct HighlightedCodeWebView: UIViewRepresentable {
    let code: String
    var language: String = "python"

    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.showsVerticalScrollIndicator = true
        view.scrollView.showsHorizontalScrollIndicator = true
        view.scrollView.bounces = false
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let layout = highlightAssetLayout() else { return }

        let escaped = Self.escapeHTML(code)
        let themePath = colorScheme == .dark ? layout.cssDarkPath : layout.cssLightPath
        let normalizedLanguage = Self.normalizeLanguage(language)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <link rel="stylesheet" href="\(themePath)">
            <style>
              :root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); }
              body { margin: 0; padding: 0; background: transparent; }
              pre { margin: 0; padding: 12px; overflow: auto; }
              pre, code, .hljs { background: transparent !important; }
              code { font-size: 13px; line-height: 1.45; }
            </style>
            <script src="\(layout.highlightScriptPath)"></script>
            <script src="\(layout.pythonScriptPath)"></script>
            <script src="\(layout.rScriptPath)"></script>
          </head>
          <body>
            <pre><code class="language-\(normalizedLanguage)">\(escaped)</code></pre>
            <script>
              (function () {
                try {
                  var el = document.querySelector('pre code');
                  if (!el || !window.hljs) return;
                  hljs.highlightElement(el);
                } catch (e) {}
              })();
            </script>
          </body>
        </html>
        """

        uiView.loadHTMLString(html, baseURL: layout.baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
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

    private static func normalizeLanguage(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return "python" }
        if trimmed == "py" { return "python" }
        if trimmed.contains("python") { return "python" }
        if trimmed == "r" || trimmed == "rscript" { return "r" }
        return trimmed
    }

    private func highlightAssetLayout() -> HighlightAssetLayout? {
        let bundle: Bundle = {
#if SWIFT_PACKAGE
            return Bundle.module
#else
            return Bundle.main
#endif
        }()

        let structuredSubdirs = ["highlightjs", "Resources/highlightjs"]
        for subdir in structuredSubdirs {
            if let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js", subdirectory: subdir) {
                let base = scriptURL.deletingLastPathComponent()
                return HighlightAssetLayout(
                    baseURL: base,
                    highlightScriptPath: "highlight.min.js",
                    pythonScriptPath: "languages/python.min.js",
                    rScriptPath: "languages/r.min.js",
                    cssLightPath: "styles/github.min.css",
                    cssDarkPath: "styles/github-dark.min.css"
                )
            }
        }

        if let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js") {
            let base = scriptURL.deletingLastPathComponent()
            return HighlightAssetLayout(
                baseURL: base,
                highlightScriptPath: "highlight.min.js",
                pythonScriptPath: "python.min.js",
                rScriptPath: "r.min.js",
                cssLightPath: "github.min.css",
                cssDarkPath: "github-dark.min.css"
            )
        }

        if let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js", subdirectory: "Resources") {
            let base = scriptURL.deletingLastPathComponent()
            return HighlightAssetLayout(
                baseURL: base,
                highlightScriptPath: "highlight.min.js",
                pythonScriptPath: "python.min.js",
                rScriptPath: "r.min.js",
                cssLightPath: "github.min.css",
                cssDarkPath: "github-dark.min.css"
            )
        }

        return nil
    }
}

private struct HighlightAssetLayout: Sendable {
    var baseURL: URL
    var highlightScriptPath: String
    var pythonScriptPath: String
    var rScriptPath: String
    var cssLightPath: String
    var cssDarkPath: String
}
#endif
