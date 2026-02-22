#if os(iOS)
import SwiftUI
import WebKit

struct SanitizedHTMLWebView: UIViewRepresentable {
    let html: String

    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.showsVerticalScrollIndicator = true
        view.scrollView.showsHorizontalScrollIndicator = false
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let sanitized = Self.sanitize(html)
        let foreground = colorScheme == .dark ? "rgba(235,235,245,0.86)" : "rgba(0,0,0,0.88)"

        let wrapped = """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
              :root { color-scheme: \(colorScheme == .dark ? "dark" : "light"); }
              body {
                margin: 0;
                padding: 12px;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif;
                font-size: 14px;
                line-height: 1.45;
                color: \(foreground);
                background: transparent;
                word-wrap: break-word;
                overflow-wrap: anywhere;
              }
              img, video, canvas, svg { max-width: 100%; height: auto; }
              table { max-width: 100%; overflow-x: auto; display: block; }
              pre, code { white-space: pre-wrap; word-break: break-word; }
              a { color: inherit; text-decoration: underline; }
            </style>
          </head>
          <body>
            \(sanitized)
          </body>
        </html>
        """

        uiView.loadHTMLString(wrapped, baseURL: nil)
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

    private static func sanitize(_ input: String) -> String {
        var out = input

        out = replace(out, pattern: "(?is)<script\\b[^>]*>.*?<\\/script>", with: "")
        out = replace(out, pattern: "(?is)<iframe\\b[^>]*>.*?<\\/iframe>", with: "")
        out = replace(out, pattern: "(?is)<object\\b[^>]*>.*?<\\/object>", with: "")
        out = replace(out, pattern: "(?is)<embed\\b[^>]*>.*?<\\/embed>", with: "")
        out = replace(out, pattern: "(?is)<script\\b[^>]*\\/?>", with: "")
        out = replace(out, pattern: "(?is)<iframe\\b[^>]*\\/?>", with: "")
        out = replace(out, pattern: "(?is)<object\\b[^>]*\\/?>", with: "")
        out = replace(out, pattern: "(?is)<embed\\b[^>]*\\/?>", with: "")

        // Remove inline event handlers like onclick="..."
        out = replace(out, pattern: "(?i)\\son\\w+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "")

        // Remove external http(s) src/href attributes, allowing data: and anchors.
        out = replace(out, pattern: "(?i)\\s(?:src|href)\\s*=\\s*(\"|')https?:\\/\\/.*?\\1", with: "")
        out = replace(out, pattern: "(?i)\\s(?:src|href)\\s*=\\s*(\"|')javascript:.*?\\1", with: "")

        return out
    }

    private static func replace(_ input: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: replacement)
    }
}
#endif
