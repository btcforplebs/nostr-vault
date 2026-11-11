import SwiftUI

#if os(macOS)

/// The numbers the Mac glass surfaces show, each from a source that exists
/// today (RESEARCH/NV_MAC_RELAY_STATS_INVENTORY.md row numbers in brackets).
/// Nothing here is invented: a value that is not known reads as unknown.
/// Nothing here walks the disk either (#6 stays off these surfaces).
@MainActor
enum MacVaultGlance {
    // MARK: State (#1)

    static func glow(_ relay: RelayProcessManager) -> MacVaultArchMark.Glow {
        if relay.isBooting || relay.isImporting { return .busy }
        return relay.isRunning ? .running : .stopped
    }

    static func stateLabel(_ relay: RelayProcessManager) -> String {
        if relay.isBooting { return "Starting" }
        if relay.isImporting { return "Importing" }
        if relay.isRunning && relay.isWotSyncing { return "Syncing" }
        return relay.isRunning ? "Running" : "Stopped"
    }

    static func stateTint(_ relay: RelayProcessManager) -> Color {
        if relay.isBooting || relay.isImporting || relay.isWotSyncing { return .havenPurple }
        return relay.isRunning ? .havenOnline : .red
    }

    // MARK: Uptime (#2): relay uptime from startDate, not app uptime.

    static func uptime(_ relay: RelayProcessManager, now: Date) -> String? {
        guard relay.isRunning, let start = relay.startDate else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        if days > 0 { return "up \(days) d \(hours) h" }
        if hours > 0 { return "up \(hours) h \(mins) m" }
        return "up \(mins) m"
    }

    // MARK: Connections (#3)

    /// `activeConnections` is only refreshed when the relay logs a connect or
    /// disconnect, so a surface that opens reads it fresh first.
    static func refreshConnections(_ relay: RelayProcessManager) {
        guard relay.isRunning else { return }
        relay.activeConnections = max(0, Int(ActiveConnectionsC()))
    }

    static func connections(_ relay: RelayProcessManager) -> String? {
        guard relay.isRunning else { return nil }
        return "\(relay.activeConnections) connected"
    }

    // MARK: Stored (#4): an estimate from log lines, so always "about".

    static func stored(_ stats: StatsService) -> String {
        let count = stats.loadedEventsCount
        guard count > 0 else { return "No events yet" }
        return "about \(count.formatted(.number))"
    }

    // MARK: Mesh (#17 + #18): My Devices that the engine is connected to now.

    static func mesh(_ mesh: MacFipsMeshService, config: HavenConfig) -> String {
        guard mesh.enabled else { return "Off" }
        let devices = config.meshDevices
        guard !devices.isEmpty else { return "No devices" }
        guard mesh.running else { return "Not running" }
        let peers = Set(mesh.status?.peers ?? [])
        let inReach = devices.filter { peers.contains($0.npub) }.count
        return "\(inReach) of \(devices.count) in reach"
    }

    // MARK: Outbox (#19): media posts waiting for a server. Hidden at zero.

    static func outbox(_ queue: MediaPostQueue) -> String? {
        let waiting = queue.posts.count
        return waiting > 0 ? "\(waiting) waiting" : nil
    }

    // MARK: Running job (#14 import, boot): no percentage, it is partly synthetic.

    static func job(_ relay: RelayProcessManager) -> String? {
        if relay.isImporting {
            let message = relay.importStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Importing" : message
        }
        if relay.isBooting {
            let message = relay.bootStatusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "Starting your vault" : message
        }
        return nil
    }
}

#endif
