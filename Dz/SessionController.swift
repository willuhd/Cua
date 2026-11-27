//
//  SessionController.swift
//  dz
//
//  Owns whichever session is running and the window the client draws into.
//
//  One session at a time, in either role. dz is the same app on both machines,
//  so "host" and "client" are modes of this process, not different builds.
//

import Cocoa

final class SessionController: NSObject {
    static let shared = SessionController()

    enum Role: String {
        case host, client
    }

    private(set) var role: Role?
    private var host: HostSession?
    private var client: ClientSession?
    private var window: NSWindow?
    private var share: WebDAVServer?
    static let sharePort: UInt16 = 47_101

    /// Called when a session starts or stops so the menubar can update.
    var onChange: (() -> Void)?

    var isRunning: Bool { role != nil }

    /// Everything the popover needs to render the Remote tab.
    var snapshot: [String: Any] {
        var out: [String: Any] = ["role": role?.rawValue ?? "idle", "status": status]
        switch role {
        case .host:
            out["frames"] = host?.framesSent ?? 0
            out["packets"] = host?.packetsSent ?? 0
            out["bytes"] = host?.bytesSent ?? 0
            out["fps"] = host?.measuredFps ?? 0
            out["skipped"] = host?.framesSkipped ?? 0
        case .client:
            out["frames"] = client?.framesShown ?? 0
            out["dropped"] = client?.framesDropped ?? 0
            if let stats = client?.hostStats {
                out["fps"] = stats.fps
                out["packets"] = stats.packetsSent
                out["skipped"] = stats.framesSkipped
                out["targetFps"] = stats.targetFps
            }
        case .none:
            break
        }
        return out
    }

    var status: String {
        guard let role else { return "Idle" }
        switch role {
        case .host:
            let f = host?.framesSent ?? 0
            let p = host?.packetsSent ?? 0
            return "Hosting: \(f) frames, \(p) packets"
        case .client:
            let s = client?.framesShown ?? 0
            let d = client?.framesDropped ?? 0
            return "Connected: \(s) frames shown, \(d) dropped"
        }
    }

    // MARK: - Host

    func startHosting(settings: StreamSettings) {
        guard role == nil else { return }
        do {
            let session = try HostSession(settings: settings)
            host = session
            role = .host
            onChange?()
            Task { [weak self] in
                do {
                    try await session.start()
                } catch {
                    await MainActor.run {
                        self?.present(error, title: "Could not start sharing")
                        self?.stop()
                    }
                }
            }
        } catch {
            present(error, title: "Could not start sharing")
        }
    }

    // MARK: - Client

    func connect(to address: String, settings: StreamSettings) {
        guard role == nil else { return }
        do {
            let session = try ClientSession(settings: settings, host: address)
            client = session
            role = .client
            showWindow(for: session.view, size: NSSize(width: settings.width, height: settings.height))
            session.start()
            onChange?()
        } catch {
            present(error, title: "Could not connect")
        }
    }

    private func showWindow(for view: StreamView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "dz"
        window.contentView = view
        // The view takes focus for input; the window must not eat key events.
        window.makeFirstResponder(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        self.window = window
    }

    // MARK: - file share

    /// Starts or stops serving a folder to the other Mac. The folder is the
    /// user's choice; nothing is shared until one is picked.
    func updateShare() {
        share?.stop()
        share = nil
        guard let folder = MCPServer.shareFolder, !folder.isEmpty else { onChange?(); return }
        let requirePassword = UserDefaults.standard.object(forKey: "dz.share.auth") as? Bool ?? true
        let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let server = WebDAVServer(root: url, port: Self.sharePort,
                                  token: requirePassword ? MCPServer.remoteToken : "")
        if server.start() { share = server }
        onChange?()
    }

    var shareStatus: [String: Any] {
        let folder = MCPServer.shareFolder ?? ""
        let requirePassword = UserDefaults.standard.object(forKey: "dz.share.auth") as? Bool ?? true
        return ["folder": folder, "port": Int(Self.sharePort), "active": share != nil,
                "requiresPassword": requirePassword,
                "address": MCPServer.sharedAddress() ?? ""]
    }

    // MARK: - Stop

    func stop() {
        host?.stop()
        client?.stop()
        host = nil
        client = nil
        role = nil
        window?.orderOut(nil)
        window = nil
        onChange?()
    }

    private func present(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

extension SessionController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if role == .client { stop() }
    }
}
