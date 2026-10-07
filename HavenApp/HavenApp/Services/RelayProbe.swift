import Foundation

/// Measures how long each relay takes to answer, from this device: open a
/// socket, ask for one event, and time the first reply (EVENT, EOSE, NOTICE
/// or CLOSED, any answer counts). Feeds the relay matrix's health dots.
@MainActor
final class RelayProbe: ObservableObject {

    enum Result: Equatable {
        case probing
        case answered(milliseconds: Int)
        case unreachable
    }

    /// Slower than this shows as "slow".
    static let slowMilliseconds = 500
    static let timeout: TimeInterval = 6

    @Published private(set) var results: [String: Result] = [:]

    func result(for url: String) -> Result? { results[RelayMatrix.key(url)] }

    /// Probes every relay in `urls` at once. A relay already being probed is
    /// left alone.
    func probe(_ urls: [String]) {
        for url in urls {
            let key = RelayMatrix.key(url)
            guard results[key] != .probing, let parsed = URL(string: HavenConfig.normalizedRelayURL(url)) else { continue }
            results[key] = .probing
            Task {
                let result = await Self.measure(parsed)
                self.results[key] = result
            }
        }
    }

    var unreachable: [String] {
        results.compactMap { $0.value == .unreachable ? $0.key : nil }.sorted()
    }

    nonisolated private static func measure(_ url: URL) async -> Result {
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        let start = Date()
        task.resume()
        let request = #"["REQ","nv-probe",{"kinds":[0],"limit":1}]"#
        return await withTaskGroup(of: Result.self) { group in
            group.addTask {
                do {
                    try await task.send(.string(request))
                    _ = try await task.receive()
                    return .answered(milliseconds: Int(Date().timeIntervalSince(start) * 1000))
                } catch {
                    return .unreachable
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .unreachable
            }
            let first = await group.next() ?? .unreachable
            group.cancelAll()
            task.cancel(with: .goingAway, reason: nil)
            return first
        }
    }
}
