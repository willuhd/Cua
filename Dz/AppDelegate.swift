import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var popVC: PopoverVC!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("menubar-mcp")
        NSApp.setActivationPolicy(.accessory)
        // load menubar icon: MenuIcon.png is the template (Finder icon is the
        // Icon Composer AppIcon.icon, separate). Fall back to an arrow if missing.
        var img: NSImage?
        if let path = Bundle.main.path(forResource: "MenuIcon", ofType: "png") {
            img = NSImage(contentsOfFile: path)
        }
        if let img = img {
            let sized = NSImage(size: NSSize(width: 18, height: 18))
            sized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            sized.unlockFocus()
            sized.isTemplate = true
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = sized
            statusItem.button?.image?.isTemplate = true
        } else {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.title = "➤"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popVC = PopoverVC()
        popover = NSPopover()
        popover.contentViewController = popVC
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 360)
        popVC.onHeight = { [weak self] h in
            self?.popover.contentSize = NSSize(width: 360, height: h)
        }

        // Permissions are prompted from the popover's grant button, never on launch.
        let refreshUI = { [weak self] in
            DispatchQueue.main.async { self?.popVC.updateTable() }
        }
        MCPServer.shared.onStateChange = refreshUI
        ForegroundCoordinator.shared.onChange = refreshUI
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.popVC.updateTable() }
        MCPServer.bindAll = MCPServer.expose
        MCPServer.shared.start(port: MCPServer.shared.port)
        SessionController.shared.updateShare()
        DispatchQueue.main.async { [weak self] in _ = self?.popVC?.view }
        clog("launched, MCP on 127.0.0.1:\(MCPServer.shared.port)")
    }
    /// Left click opens the lease popover; right click opens session control.
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSessionMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: - session control

    private func showSessionMenu() {
        let menu = NSMenu()
        let controller = SessionController.shared

        if controller.isRunning {
            let status = NSMenuItem(title: controller.status, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Stop Session", action: #selector(stopSession), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Share This Mac", action: #selector(startHosting), keyEquivalent: "")
            menu.addItem(withTitle: "Connect to Host\u{2026}", action: #selector(connectToHost), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit dz", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach again so the next left click opens the popover, not the menu.
        statusItem.menu = nil
    }

    @objc private func startHosting() {
        SessionController.shared.startHosting(settings: StreamProfile.load())
    }

    @objc private func connectToHost() {
        let alert = NSAlert()
        alert.messageText = "Connect to a Mac running dz"
        alert.informativeText = "Host name or address. The other machine needs dz sharing this Mac."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = "127.0.0.1"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        SessionController.shared.connect(to: address, settings: StreamProfile.load())
    }

    @objc private func stopSession() {
        SessionController.shared.stop()
    }

    @objc private func quit() {
        SessionController.shared.stop()
        NSApp.terminate(nil)
    }

    @objc func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown { popover.close() }
        else { popVC.refresh(); popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        ForegroundCoordinator.shared.stop()
        MCPServer.shared.stop()
    }
}

