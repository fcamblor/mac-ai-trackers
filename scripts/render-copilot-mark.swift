// One-shot generator for Sources/App/Resources/VendorBranding/copilot-mark.pdf.
//
// Renders the GitHub Octicons `copilot-24` glyph (MIT-licensed, primer/octicons)
// into a single-page PDF via WKWebView's `createPDF`. Run from the repo root:
//
//   swift scripts/render-copilot-mark.swift
//
// Re-run only if the source SVG below is updated; the resulting PDF is meant
// to be checked in alongside claude-mark.pdf and codex-mark.pdf so the app
// has a static asset to load (the runtime never invokes WebKit).
import AppKit
import WebKit

// Source: https://github.com/primer/octicons (MIT license), copilot-24.svg.
// Trimmed to just the glyph paths inside a 24×24 viewBox; the surrounding
// HTML scales the SVG to a square of `pageSize` points so the resulting PDF
// is roughly the same density as the other vendor marks.
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%">
  <path d="M23.922 16.992c-.861 1.495-5.859 5.023-11.922 5.023-6.063 0-11.061-3.528-11.922-5.023A.641.641 0 0 1 0 16.736v-2.869a.841.841 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.195 10.195 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952 1.399-1.136 3.392-2.093 6.122-2.093 2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.832.832 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256ZM12.172 11h-.344a4.323 4.323 0 0 1-.355.508C10.703 12.455 9.555 13 7.965 13c-1.725 0-2.989-.359-3.782-1.259a2.005 2.005 0 0 1-.085-.104L4 11.741v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.323 4.323 0 0 1-.355-.508h-.016.016Zm.641-2.935c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"/>
  <path d="M14.5 14.25a1 1 0 0 1 1 1v2a1 1 0 0 1-2 0v-2a1 1 0 0 1 1-1Zm-5 0a1 1 0 0 1 1 1v2a1 1 0 0 1-2 0v-2a1 1 0 0 1 1-1Z"/>
</svg>
"""

// Match the visual weight of claude-mark.pdf / codex-mark.pdf (~24×24 design).
let pageSize: CGFloat = 24

let html = """
<!DOCTYPE html>
<html><head><style>
  html, body { margin: 0; padding: 0; width: \(pageSize)px; height: \(pageSize)px; background: transparent; }
  svg { display: block; width: 100%; height: 100%; }
</style></head>
<body>\(svg)</body></html>
"""

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let outputURL: URL
    let webView: WKWebView
    let done: () -> Void

    init(outputURL: URL, done: @escaping () -> Void) {
        self.outputURL = outputURL
        self.done = done
        let config = WKWebViewConfiguration()
        // Setting an explicit frame ensures the PDF page matches the SVG canvas
        // 1:1 — defaults to 800pt-wide which would oversize the asset.
        let frame = NSRect(x: 0, y: 0, width: pageSize, height: pageSize)
        self.webView = WKWebView(frame: frame, configuration: config)
        self.webView.setValue(false, forKey: "drawsBackground")
        super.init()
        self.webView.navigationDelegate = self
    }

    func start() {
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = NSRect(x: 0, y: 0, width: pageSize, height: pageSize)
        webView.createPDF(configuration: pdfConfig) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    try data.write(to: self.outputURL, options: .atomic)
                    print("Wrote \(self.outputURL.path) (\(data.count) bytes)")
                } catch {
                    fputs("Failed to write PDF: \(error)\n", stderr)
                    exit(1)
                }
            case .failure(let error):
                fputs("createPDF failed: \(error)\n", stderr)
                exit(1)
            }
            self.done()
        }
    }
}

let outputPath = FileManager.default.currentDirectoryPath
    + "/AIUsagesTrackers/Sources/App/Resources/VendorBranding/copilot-mark.pdf"
let outputURL = URL(fileURLWithPath: outputPath)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

DispatchQueue.main.async {
    let renderer = Renderer(outputURL: outputURL) {
        DispatchQueue.main.async { app.terminate(nil) }
    }
    renderer.start()
    // Hold a strong reference until termination — script lifetime is fine.
    objc_setAssociatedObject(app, "renderer", renderer, .OBJC_ASSOCIATION_RETAIN)
}

app.run()
