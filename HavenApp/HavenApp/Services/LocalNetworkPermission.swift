import Foundation
import Network

/// Asks for local-network access up front. iOS (and macOS 15+) shows its
/// prompt on the first packet to the local network; for a copy that was
/// the mesh reaching the other device mid-copy, over the progress bar
/// (Logen's iPad ← Mac run, 2026-11-06). `ask()` sends one UDP packet to
/// the Wi-Fi router so the prompt comes up on the copy step, before the
/// scan. Nothing listens for it and nothing is read back.
enum LocalNetworkPermission {
    private static var asked = false

    static func ask() {
        guard !asked, let target = routerAddress() else { return }
        asked = true
        let conn = NWConnection(host: NWEndpoint.Host(target), port: 9, using: .udp) // discard
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: Data([0]), completion: .contentProcessed { _ in conn.cancel() })
            case .failed, .waiting:
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    /// x.y.z.1 on the Wi-Fi (or wired) interface's private IPv4 network, or
    /// nil off a local network.
    static func routerAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            if let router = routerFor(String(cString: host)) { return router }
        }
        return nil
    }

    /// The .1 of a private IPv4 address's /24, or nil for anything else.
    static func routerFor(_ ip: String) -> String? {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, p.allSatisfy({ (0...255).contains($0) }) else { return nil }
        let isPrivate = p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
        guard isPrivate else { return nil }
        return "\(p[0]).\(p[1]).\(p[2]).1"
    }
}
