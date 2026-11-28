// dz — menubar + MCP app (contained, in-memory).
// Double-click dz.app -> menubar cursor icon. Click icon -> popover listing
// held apps + MCP port field. MCP over streamable HTTP on 127.0.0.1:3060.
// Everything hot (images, cursor pointers) lives in RAM. No /tmp, no cursor.json.
//
// Leases: acquire(pid|app, scope=app|window) -> acquisitionId (short 8-char ID,
// not cryptographic). App and window leases are mutually exclusive; multiple
// window leases may coexist. Every action carries the lease id. Rejected/held
// calls return LEASE_HELD or INVALID_ID with a user-facing hint.
//
// Coordinates: each lease declares image | norm1000 | screen; all
// spatial tools inherit it. Screenshots return geometry and cache the full-res
// source for zoom crops.
//
// Foreground: request_foreground waits for explicit menubar approval, revokes
// every background lease, and gives the agent the real pointer/focus for the
// whole Mac. It runs until released or stopped. Human input invalidates the
// last screenshot until the agent re-observes. Only one grant can exist.
//
// Build: Xcode project (dz.xcodeproj, target dz, macOS 14.0, com.willuhd.dz).
//   xcodebuild -project dz.xcodeproj -target dz -configuration Release build CODE_SIGNING_ALLOWED=NO
//   XB=$(xcodebuild -project dz.xcodeproj -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}')
//   cp -R "$XB/Release/dz.app" dz.app
//   find dz.app/Contents/Frameworks -name '*.dylib' -exec codesign --force --sign - {} \;
//   codesign --force --sign - dz.app   (inside out, no --deep, no hardened runtime)
// No ObjC: pure Swift. SkyLight arrives via dlopen, no bridging header.
// Codesign adhoc; same bundle id com.willuhd.dz so the one TCC checkbox survives.

// MARK: – entry
import Cocoa

@main
struct DzMain {
    static func main() {
        // A headless check, so the pipeline can be proven without a window or
        // a second machine.
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--capture-check") {
            exit(SelfTest.captureCheck())
        }
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        // The delegate property is weak; this local keeps it alive for the run loop.
        _ = d
        app.run()
    }
}
