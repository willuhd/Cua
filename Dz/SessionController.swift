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

/// The profile a session starts with. Pinned, never adjusted: these are the
/// numbers to beat, chosen for the Intel client at 1080p and a constrained link.
enum HostSessionDefaults {
    static var settings: StreamSettings {
        var s = StreamSettings()
        s.width = 1920
        s.height = 1080
        s.frameRate = 75
        s.bitrate = 8_000_000
        s.preset = 10
        s.rateControl = .cbr
        s.fecOverhead = 0.2
        s.jitterFrames = 3
        s.pointer = .free
        return s
    }
}

final class SessionController: NSObject {
    static let shared = SessionController()

    enum Role: String {
        case host, client
    }

    private(set) var role: Role?
    private var host: HostSession?
    private var client: ClientSession?
    private var window: NSWindow?

    /// Called when a session starts or stops so the menubar can update.
    var onChange: (() -> Void)?

    var isRunning: Bool { role != nil }

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
