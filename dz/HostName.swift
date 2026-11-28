import Foundation

enum HostName {
    static func current() -> String {
        if let name = Host.current().localizedName, !name.isEmpty { return name }
        return ProcessInfo.processInfo.hostName
    }
}
