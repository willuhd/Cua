import Cocoa
import WebKit

// MARK: - web UI (dz/index.html, transparent over native glass)
// Single source of truth is dz/index.html, copied into the bundle as a
// resource. At runtime try, in order: the bundled copy, then the file beside
// the sources (#filePath, dev), then a minimal fallback so the server never
// returns an empty page.
let webUIHTML: String = {
    // 1) bundle resource
    if let path = Bundle.main.path(forResource: "index", ofType: "html"),
       let s = try? String(contentsOfFile: path, encoding: .utf8) {
        return s
    }
    // 2) dev: index.html beside this file (ad-hoc personal build)
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidate = here.appendingPathComponent("index.html")
    if let s = try? String(contentsOf: candidate, encoding: .utf8) {
        return s
    }
    // 3) fallback: server is up, UI file missing - keep the page non-empty
    return "<!DOCTYPE html><html><body><h1>dz</h1><p>UI file (index.html) not found. Server is running.</p></body></html>"
}()

// MARK: – native drag source for the permission icon
final class AppDragView: NSView, NSDraggingSource {
    let fileURL: URL
    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
        icon.size = NSSize(width: 32, height: 32)
        drag.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {}
}

// MARK: – menubar UI
final class PopoverVC: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    var webView: WKWebView!
    var heightConstraint: NSLayoutConstraint!
    var onHeight: ((CGFloat) -> Void)?
    private var permDrag: AppDragView?

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
        wm.userContentController.add(self, name: "dzHeight")
        wm.userContentController.add(self, name: "dzPermRect")
        let token = MCPServer.shared.uiToken.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let tokenScript = WKUserScript(source: "window.__DZ_UI_TOKEN = \"\(token)\"",
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
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "dzHeight" {
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
        guard message.name == "dzPermRect", let dict = message.body as? [String: Any] else { return }
        let show = (dict["show"] as? Bool) ?? ((dict["show"] as? NSNumber)?.boolValue ?? false)
        guard show,
              let x = (dict["x"] as? NSNumber)?.doubleValue,
              let y = (dict["y"] as? NSNumber)?.doubleValue,
              let w = (dict["width"] as? NSNumber)?.doubleValue,
              let h = (dict["height"] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else {
            permDrag?.isHidden = true
            return
        }
        if permDrag == nil {
            let drag = AppDragView(fileURL: Bundle.main.bundleURL)
            drag.autoresizingMask = []
            view.addSubview(drag, positioned: .above, relativeTo: webView)
            permDrag = drag
        }
        let top = webView.bounds.height - CGFloat(y) - CGFloat(h)
        permDrag?.frame = NSRect(x: CGFloat(x), y: top, width: CGFloat(w), height: CGFloat(h))
        permDrag?.isHidden = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { clog("webview fail: \(error.localizedDescription)") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { clog("webview provisional fail: \(error.localizedDescription)") }
    func updateTable() {
        guard isViewLoaded else { return }
        if webView.url?.absoluteString == url().absoluteString {
            webView.evaluateJavaScript("refresh()")
        }
    }
    func refresh() {
        guard isViewLoaded else { return }
        if webView.url?.absoluteString == url().absoluteString {
            webView.evaluateJavaScript("refresh(true)")
        } else {
            webView.load(URLRequest(url: url()))
        }
    }
}
