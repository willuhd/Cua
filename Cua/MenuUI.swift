import Cocoa
import ApplicationServices
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Network
import WebKit
import Darwin

// MARK: - web UI (src/index.html, transparent over native glass)
// Single source of truth is src/index.html. At runtime try, in order:
// bundle resource (Contents/Resources/index.html), then src/index.html next to
// the sources (#filePath, dev), then a minimal fallback so the server never
// returns an empty page.
let webUIHTML: String = {
    // 1) bundle resource
    if let path = Bundle.main.path(forResource: "index", ofType: "html"),
       let s = try? String(contentsOfFile: path, encoding: .utf8) {
        return s
    }
    // 2) dev: src/index.html beside this file (ad-hoc personal build)
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidate = here.appendingPathComponent("index.html")
    if let s = try? String(contentsOf: candidate, encoding: .utf8) {
        return s
    }
    // 3) fallback: server is up, UI file missing - keep the page non-empty
    return "<!DOCTYPE html><html><body><h1>Cua</h1><p>UI file (index.html) not found. Server is running.</p></body></html>"
}()

// MARK: – menubar UI
final class PopoverVC: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var heightConstraint: NSLayoutConstraint!
    var onHeight: ((CGFloat) -> Void)?

    func url() -> URL { URL(string: "http://127.0.0.1:\(MCPServer.shared.port)/")! }

    override func loadView() {
        // Single material: the popover window's own glass. No inner effect view
        // (its edge is the seam at the arrow). Plain layer-backed container just
        // hosts the WebView layer so it composites and renders.
        let fx = NSView()
        fx.wantsLayer = true
        fx.layer?.isOpaque = false
        fx.layer?.backgroundColor = NSColor.clear.cgColor
        fx.translatesAutoresizingMaskIntoConstraints = false
        view = fx

        let wm = WKWebViewConfiguration()
        wm.websiteDataStore = .nonPersistent()
        wm.userContentController.add(self, name: "cuaHeight")
        let token = MCPServer.shared.uiToken.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let tokenScript = WKUserScript(source: "window.__CUA_UI_TOKEN = \"\(token)\"",
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true)
        wm.userContentController.addUserScript(tokenScript)
        webView = WKWebView(frame: .zero, configuration: wm)
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        webView.layer?.borderWidth = 0
        webView.layer?.shadowOpacity = 0
        webView.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(webView)
        heightConstraint = fx.heightAnchor.constraint(equalToConstant: 360)
        NSLayoutConstraint.activate([
            fx.widthAnchor.constraint(equalToConstant: 360),
            heightConstraint,
            webView.topAnchor.constraint(equalTo: fx.topAnchor),
            webView.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
        ])
        preferredContentSize = NSSize(width: 360, height: 360)
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url()))
        probe()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "cuaHeight" {
            let raw: CGFloat
            if let n = message.body as? NSNumber { raw = CGFloat(truncating: n) }
            else if let d = message.body as? Double { raw = CGFloat(d) }
            else { return }
            let h = max(150, min(420, raw))
            guard abs(h - heightConstraint.constant) > 0.5 else { return }
            heightConstraint.constant = h
            preferredContentSize = NSSize(width: 360, height: h)
            onHeight?(h)
            return
        }
    }

    func probe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let w = self?.webView else { return }
            w.evaluateJavaScript("document.body ? document.body.innerText.length : -1") { v, _ in clog("webview probe body=\(v ?? "nil") url=\(w.url?.absoluteString ?? "nil") loading=\(w.isLoading)") }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { clog("webview start") }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { clog("webview finish"); probe() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { clog("webview fail: \(error.localizedDescription)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { clog("webview provisional fail: \(error.localizedDescription)") }
    func updateTable() {
        guard isViewLoaded else { return }
        // JS polls /api/state itself; nothing to do here. Keep symbol for AppDelegate.
    }
    func refresh() {
        guard isViewLoaded else { return }
        if webView.url?.absoluteString == url().absoluteString {
            webView.evaluateJavaScript("refresh()")
        } else {
            webView.load(URLRequest(url: url()))
        }
    }
    func reload() {
        guard isViewLoaded else { return }
        webView.load(URLRequest(url: url()))
    }
}
