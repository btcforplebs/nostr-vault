import Foundation

/// The relay's running counters, apart from `RelayProcessManager` so a
/// change redraws only the surfaces that show them. They move on every
/// stored event and connect line; on the manager they redrew everything
/// that observes it, the feed and the tab root included, while scrolling.
@MainActor
final class RelayCounters: ObservableObject {
    static let shared = RelayCounters()
    private init() {}

    @Published var memoryUsage: Double = 0
    @Published var cpuUsage: Double = 0
    @Published var activeConnections: Int = 0
    @Published var eventsStored: Int = 0
}
