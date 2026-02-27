#if os(iOS)
import SwiftUI
import WebKit

struct HighlightedCodeWebView: UIViewRepresentable {
    let code: String
    var language: String? = nil
    var filePathForLanguageHint: String? = nil

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
        let resolvedLanguage = Self.resolveLanguage(explicitLanguage: language, filePath: filePathForLanguageHint)
        let codeClassAttribute = resolvedLanguage.map { " class=\"language-\($0)\"" } ?? ""
        let extraScripts = layout.extraLanguageScriptPaths
            .map { "<script src=\"\($0)\"></script>" }
            .joined(separator: "\n            ")

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
            \(extraScripts)
          </head>
          <body>
            <pre><code\(codeClassAttribute)>\(escaped)</code></pre>
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

    static func languageForFilePath(_ path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        guard let language = extensionLanguageMap[ext] else { return nil }
        return normalizeLanguage(language)
    }

    private static func resolveLanguage(explicitLanguage: String?, filePath: String?) -> String? {
        if let explicitLanguage, let normalized = normalizeLanguage(explicitLanguage) {
            return normalized
        }
        if let filePath {
            return languageForFilePath(filePath)
        }
        return nil
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

    private static func normalizeLanguage(_ language: String) -> String? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let canonical: String
        switch trimmed {
        case "js", "mjs", "cjs":
            canonical = "javascript"
        case "ts", "mts", "cts":
            canonical = "typescript"
        case "py", "py3", "python3":
            canonical = "python"
        case "rscript":
            canonical = "r"
        case "yml":
            canonical = "yaml"
        case "sh", "zsh", "shell":
            canonical = "bash"
        case "htm", "html":
            canonical = "xml"
        case "md":
            canonical = "markdown"
        default:
            canonical = trimmed
        }

        let sanitized = canonical.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "+" || $0 == "#" }
        return sanitized.isEmpty ? nil : sanitized
    }

    private func highlightAssetLayout() -> HighlightAssetLayout? {
        let bundle: Bundle = {
#if SWIFT_PACKAGE
            return Bundle.module
#else
            return Bundle.main
#endif
        }()

        if let layout = structuredHighlightLayout(bundle: bundle, subdirectory: "highlightjs") {
            return layout
        }
        if let layout = structuredHighlightLayout(bundle: bundle, subdirectory: "Resources/highlightjs") {
            return layout
        }
        if let layout = flatHighlightLayout(bundle: bundle, subdirectory: nil) {
            return layout
        }
        if let layout = flatHighlightLayout(bundle: bundle, subdirectory: "Resources") {
            return layout
        }
        return nil
    }

    private func structuredHighlightLayout(bundle: Bundle, subdirectory: String) -> HighlightAssetLayout? {
        guard let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js", subdirectory: subdirectory) else {
            return nil
        }
        let base = scriptURL.deletingLastPathComponent()
        let languageScripts = bundledLanguageScripts(bundle: bundle, subdirectory: "\(subdirectory)/languages", relativePrefix: "languages/")
        return HighlightAssetLayout(
            baseURL: base,
            highlightScriptPath: "highlight.min.js",
            extraLanguageScriptPaths: languageScripts,
            cssLightPath: "styles/github.min.css",
            cssDarkPath: "styles/github-dark.min.css"
        )
    }

    private func flatHighlightLayout(bundle: Bundle, subdirectory: String?) -> HighlightAssetLayout? {
        guard let scriptURL = bundle.url(forResource: "highlight.min", withExtension: "js", subdirectory: subdirectory) else {
            return nil
        }
        let base = scriptURL.deletingLastPathComponent()
        let languageScripts = bundledLanguageScripts(bundle: bundle, subdirectory: subdirectory, relativePrefix: "")
        return HighlightAssetLayout(
            baseURL: base,
            highlightScriptPath: "highlight.min.js",
            extraLanguageScriptPaths: languageScripts,
            cssLightPath: "github.min.css",
            cssDarkPath: "github-dark.min.css"
        )
    }

    private func bundledLanguageScripts(bundle: Bundle, subdirectory: String?, relativePrefix: String) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        for scriptName in Self.expandedCoreLanguageScripts {
            let resourceName = "\(scriptName).min"
            guard bundle.url(forResource: resourceName, withExtension: "js", subdirectory: subdirectory) != nil else {
                continue
            }
            let path = "\(relativePrefix)\(scriptName).min.js"
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    private static let extensionLanguageMap: [String: String] = [
        "swift": "swift",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "mts": "typescript",
        "cts": "typescript",
        "json": "json",
        "jsonl": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "sh": "bash",
        "bash": "bash",
        "zsh": "bash",
        "ksh": "bash",
        "sql": "sql",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "c": "c",
        "h": "c",
        "cc": "cpp",
        "cxx": "cpp",
        "cpp": "cpp",
        "hpp": "cpp",
        "hh": "cpp",
        "hxx": "cpp",
        "xml": "xml",
        "html": "xml",
        "htm": "xml",
        "svg": "xml",
        "xsd": "xml",
        "md": "markdown",
        "markdown": "markdown",
        "py": "python",
        "pyi": "python",
        "r": "r",
        "rmd": "r"
    ]

    private static let expandedCoreLanguageScripts: [String] = [
        "swift",
        "javascript",
        "typescript",
        "json",
        "yaml",
        "toml",
        "bash",
        "shell",
        "sql",
        "go",
        "rust",
        "java",
        "c",
        "cpp",
        "xml",
        "markdown",
        "python",
        "r"
    ]
}

private struct HighlightAssetLayout: Sendable {
    var baseURL: URL
    var highlightScriptPath: String
    var extraLanguageScriptPaths: [String]
    var cssLightPath: String
    var cssDarkPath: String
}
#endif
