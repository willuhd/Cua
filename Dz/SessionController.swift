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
    /// Why the last attempt failed, for the popover to show.
    private(set) var lastError: String?
    private var host: HostSession?
    private var client: ClientSession?
    private var window: NSWindow?
    private var windowIsClosing = false

    /// Called when a session starts or stops so the menubar can update.
    var onChange: (() -> Void)?

    var isRunning: Bool { role != nil }

    /// Everything the popover needs to render the Remote tab.
    var snapshot: [String: Any] {
        var out: [String: Any] = ["role": role?.rawValue ?? "idle", "status": status]
        if let lastError { out["error"] = lastError }
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
        lastError = nil
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
        lastError = nil
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else {
            lastError = "Enter the other Mac's address first"
            onChange?()
            return
        }
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
        // AppKit animates a close with a transform animation whose teardown is
        // what crashed: the window was freed while that animation was still
        // being released. There is nothing to animate here anyway.
        window.animationBehavior = .none
        window.contentView = view
        // The view takes focus for input; the window must not eat key events.
        window.makeFirstResponder(view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        self.window = window
    }

    // MARK: - file share

    /// The folder this Mac offers to the other one's agents. Nothing is
    /// shared until a folder is picked.
    var shareStatus: [String: Any] {
        ["folder": MCPServer.shareFolder ?? ""]
    }

    func updateShare() {
        onChange?()
    }

    // MARK: - Stop

    func stop() {
        host?.stop()
        client?.stop()
        host = nil
        client = nil
        role = nil
        // orderOut on a window that is already closing starts a second
        // transition, so it is skipped in that case.
        if !windowIsClosing { window?.orderOut(nil) }
        windowIsClosing = false
        window = nil
        onChange?()
    }

    private func present(_ error: Error, title: String) {
        lastError = title + ": " + String(describing: error)
        onChange?()
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
        // Nothing is released here. Dropping the last reference to a window
        // inside its own close notification frees it while AppKit is still
        // unwinding the close, which is what was taking the process down.
        let closing = notification.object as? NSWindow
        windowIsClosing = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window === closing { self.window = nil }
            if self.role == .client { self.stop() }
        }
    }
}
