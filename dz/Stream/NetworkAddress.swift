import Foundation

enum NetworkAddress {
    /// Resolves a host name or numeric IPv4 address. dz talks over the tailnet,
    /// whose MagicDNS names are as valid as its 100.x addresses.
    static func ipv4(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var numeric = in_addr()
        if inet_pton(AF_INET, trimmed, &numeric) == 1 { return trimmed }

        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(trimmed, "47901", &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard first.pointee.ai_family == AF_INET, let raw = first.pointee.ai_addr else { return nil }

        let socketAddress = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var address = socketAddress.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: text)
    }
}
