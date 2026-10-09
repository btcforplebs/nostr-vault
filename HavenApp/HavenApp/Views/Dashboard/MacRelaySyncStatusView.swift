import SwiftUI

#if os(iOS)
/// State of the Mac relay copy. Syncing with the Mac is done by the embedded
/// relay itself (the Mac is one of its relays); this shows the one-time
/// full-history copy and its missing-events check, and re-runs them on demand.
struct MacRelaySyncStatusView: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var relayManager = RelayProcessManager.shared
    @State private var status: RelayConfiguration.MacSyncStatus?
    @State private var checkRequested = false

    private var configuredMac: String {
        RelayConfiguration.macRelayURL(config: configService.config)
    }

    /// The relay reads the Mac address only when it starts, so a new address
    /// does nothing — and a check would run against the old one — until the
    /// relay restarts onto it. Saving the address in Settings does that
    /// automatically; the headline only says "Restarting" while it happens.
    private var needsRestart: Bool {
        guard relayManager.isRunning, let running = relayManager.lastConfig else { return false }
        return RelayConfiguration.macRelayURL(config: running) != configuredMac
    }

    private var isForCurrentMac: Bool {
        status?.macURL == configuredMac
    }

    /// A copy refreshes its heartbeat every 20s; one silent for 90s died with
    /// its relay and is retried on the next start.
    private var isStale: Bool {
        guard let beat = status?.updatedAt ?? status?.startedAt else { return true }
        return Date().timeIntervalSince1970 - TimeInterval(beat) > 90
    }

    private var isRunning: Bool {
        isForCurrentMac && status?.state == "running" && !isStale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isRunning || checkRequested {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).foregroundColor(iconColor)
                }
                Text(headline)
                    .font(.appSystem(size: 13, weight: .semibold))
            }
            if let detail {
                Text(detail)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Button {
                checkRequested = true
                RequestMacSyncCheckC()
            } label: {
                Label("Check sync with Mac", systemImage: "arrow.triangle.2.circlepath")
                    .font(.appSystem(size: 12, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.havenPurple)
            .disabled(isRunning || checkRequested || needsRestart || !relayManager.isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            // The copy runs inside the relay; poll its status file while visible.
            var requestedAt: Date?
            while !Task.isCancelled {
                let latest = RelayConfiguration.macSyncStatus(under: ConfigService.shared.relayDataDir)
                if checkRequested {
                    requestedAt = requestedAt ?? Date()
                    let pickedUp = latest?.state == "running" || (latest?.startedAt ?? 0) > (status?.startedAt ?? 0)
                    // Never spin forever: a request the relay didn't take
                    // (not running yet, or already mid-copy) clears itself.
                    if pickedUp || Date().timeIntervalSince(requestedAt!) > 30 {
                        checkRequested = false
                        requestedAt = nil
                    }
                }
                status = latest
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private var icon: String {
        guard isForCurrentMac, let state = status?.state else { return "clock" }
        switch state {
        case "done": return "checkmark.circle.fill"
        case "incomplete": return "exclamationmark.triangle.fill"
        case "failed": return "xmark.octagon.fill"
        default: return "clock"
        }
    }

    private var iconColor: Color {
        guard isForCurrentMac else { return .secondary }
        switch status?.state {
        case "done": return .havenOnline
        case "incomplete": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }

    private var headline: String {
        if needsRestart {
            return relayManager.isApplyingConfig
                ? "Restarting the relay to use this Mac address…"
                : "This Mac address applies when the relay next starts"
        }
        if checkRequested { return "Checking with your Mac…" }
        guard isForCurrentMac, let status, let state = status.state else {
            return "Full copy from your Mac hasn't run yet"
        }
        switch state {
        case "running":
            return isStale ? "Copy was interrupted" : "Copying your full history from the Mac…"
        case "done":
            return (status.missing ?? 0) < 0 ? "Copied (this Mac can't be checked)" : "Everything copied · 0 missing"
        case "incomplete":
            let missing = status.missing ?? 0
            return missing > 0 ? "\(missing) still missing" : "Copy didn't finish"
        case "failed": return "Couldn't copy from your Mac"
        default: return state
        }
    }

    private var detail: String? {
        guard isForCurrentMac, let status else {
            return "It starts on its own shortly after the relay starts. After that, new posts and mentions keep syncing on their own."
        }
        if status.state == "running" {
            return isStale ? "The app closed during the copy. It picks up again next time the relay starts." : nil
        }
        var parts: [String] = []
        parts.append("\(status.posts ?? 0) posts and \(status.mentions ?? 0) mentions copied.")
        if let finished = status.finishedAt {
            let date = Date(timeIntervalSince1970: TimeInterval(finished))
            parts.append("Checked \(date.formatted(date: .abbreviated, time: .shortened)).")
        }
        if status.state == "incomplete" || status.state == "failed" {
            if let error = status.error, !error.isEmpty { parts.append(error) }
            parts.append("It tries again next time the app starts.")
        }
        if (status.missing ?? 0) < 0 {
            parts.append("Your Mac's relay is too old to compare lists, so it was copied page by page.")
        }
        return parts.joined(separator: " ")
    }
}
#endif
