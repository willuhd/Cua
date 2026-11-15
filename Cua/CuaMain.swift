// Cua — menubar + MCP app (contained, in-memory).
// Double-click Cua.app -> menubar cursor icon. Click icon -> popover listing
// held apps + MCP port field. MCP over streamable HTTP on 127.0.0.1:3060.
// Everything hot (images, cursor pointers) lives in RAM. No /tmp, no cursor.json.
//
// Lease: acquire(pid|app) -> acquisitionId (short 8-char ID, not cryptographic). Every later call carries it.
// No heartbeat, no timeout, no epoch. If held, acquire returns LEASE_HELD with
// a hint telling the agent to ask the user to free the lease in the UI.
// Stale/unknown ID returns INVALID_ID with a hint to register first.
// User frees via popover; next acquire rotates to a fresh ID.
//
// Build: Xcode project (Cua.xcodeproj, target Cua, macOS 13.0, com.willuhd.Cua).
//   xcodebuild -project Cua.xcodeproj -scheme Cua -configuration Release build CODE_SIGNING_ALLOWED=NO
//   XB=$(xcodebuild -project Cua.xcodeproj -showBuildSettings | grep BUILT_PRODUCTS_DIR | awk '{print $3}')
//   cp -R "$XB/Release/Cua.app" Cua.app
//   codesign --force -s - --identifier com.willuhd.Cua Cua.app   (ad-hoc; keep id stable for TCC)
// No ObjC: pure Swift. SkyLight arrives via dlopen, no bridging header.
// Codesign adhoc; same bundle id com.willuhd.Cua so the one TCC checkbox survives.

// MARK: – entry
import Cocoa

@main
struct CuaMain {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        // Keep the delegate alive for the runloop (NSApplicationMain retains it via delegate property)
        _ = d
        app.run()
    }
}
