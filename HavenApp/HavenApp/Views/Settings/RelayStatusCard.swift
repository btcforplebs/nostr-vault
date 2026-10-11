import SwiftUI

/// The first thing on the Settings screen: whether this device's Vault relay
/// is running and where it answers. A saved change the relay reads at start
/// restarts it automatically; the card shows "Restarting…" meanwhile.
///
/// This replaces a purple "Restart Required" banner that appeared from
/// nowhere and never said which relay it meant — people with a Mac relay
/// assumed it meant that one.
struct RelayStatusCard: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager

    private enum Status {
        case running, starting, restarting, stopped

        var label: String {
            switch self {
            case .running: return "Running"
            case .starting: return "Starting…"
            case .restarting: return "Restarting…"
            case .stopped: return "Stopped"
            }
        }

        var color: Color {
            switch self {
            case .running: return .havenOnline
            case .starting, .restarting: return .orange
            case .stopped: return .red
            }
        }
    }

    private var status: Status {
        if relayManager.isApplyingConfig { return .restarting }
        if relayManager.isBooting { return .starting }
        return relayManager.isRunning ? .running : .stopped
    }

    /// The public domain when one is set (Mac), otherwise the loopback
    /// address the app itself talks to.
    private var address: String {
        let domain = configService.config.sanitizedRelayURL
        if !domain.isEmpty && !configService.config.isLocal {
            return "wss://\(domain)"
        }
        return "ws://127.0.0.1:\(configService.config.relayPort)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.havenPurple.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.appSystem(size: 20, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Vault Relay")
                        .font(.appHeadline)
                        .settingInfo(.relayStatus)
                    Text(address)
                        .font(.appSystem(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.appSubheadline.weight(.semibold))
                        .foregroundColor(status.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Relay \(status.label)")
            }

            if status == .stopped {
                Button {
                    relayManager.startRelay(config: configService.config)
                } label: {
                    Label("Start Relay", systemImage: "play.fill")
                        .font(.appSubheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.havenOnline.opacity(0.18))
                        .foregroundColor(.havenOnline)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.platformControlBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
