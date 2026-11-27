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
        statusItem.button?.action = #selector(togglePopover)
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
        MCPServer.shared.start(port: MCPServer.shared.port)
        DispatchQueue.main.async { [weak self] in _ = self?.popVC?.view }
        clog("launched, MCP on 127.0.0.1:\(MCPServer.shared.port)")
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

