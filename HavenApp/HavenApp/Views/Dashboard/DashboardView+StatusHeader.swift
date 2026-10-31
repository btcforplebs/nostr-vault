import SwiftUI

extension DashboardView {
    // MARK: - Status header

    private var statusColor: Color {
        if relayManager.isBooting { return .yellow }
        guard relayManager.isRunning else { return .red }
        return relayManager.isWotSyncing ? .orange : .havenOnline
    }

    private var statusTitle: String {
        if relayManager.isBooting { return "BOOTING" }
        guard relayManager.isRunning else { return "OFFLINE" }
        // The dot has always turned orange during a web-of-trust sync, but the
        // label said ONLINE in both branches — an unexplained colour change.
        return relayManager.isWotSyncing ? "SYNCING" : "ONLINE"
    }

    /// Drives the halo and the expanding ring. `Motion.ambientPulse` is `nil`
    /// under Reduce Motion, so the guard sits on the assignment too, or the
    /// halo is stranded mid-pulse. The loop is attached to the indicator with
    /// `.animation(_:value:)`, not `withAnimation`: this runs from `onAppear`
    /// while the dashboard sheet is presenting, and a repeat-forever
    /// transaction there also caught the sheet's Done button, which then
    /// pulsed for as long as the sheet was open.
    private func syncStatusPulse() {
        statusAnimate = (relayManager.isRunning || relayManager.isBooting)
            && Motion.ambientPulse != nil
    }

    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.15))
                .frame(width: 24, height: 24)
                .scaleEffect(statusAnimate ? 1.3 : 1.0)

            Circle()
                .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .scaleEffect(statusAnimate ? 1.5 : 1.0)
                .opacity(statusAnimate ? 0.0 : 1.0)

            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .shadow(color: statusColor.opacity(0.8), radius: 4)
        }
        .animation(statusAnimate ? Motion.ambientPulse : Motion.fade, value: statusAnimate)
        .accessibilityHidden(true)
    }

    private func uptimeText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func liveMetaText(now: Date) -> String {
        var parts: [String] = []
        if let start = relayManager.startDate {
            parts.append("up \(uptimeText(since: start, now: now))")
        }
        let count = relayManager.activeConnections
        parts.append(count == 1 ? "1 connection" : "\(count) connections")
        return parts.joined(separator: " · ")
    }

    private func copyRelayAddress() {
        let address = configService.config.nostrURL
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        #else
        UIPasteboard.general.string = address
        #endif
        withAnimation(Motion.control) { didCopyAddress = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(Motion.control) { didCopyAddress = false }
        }
    }

    /// The address the relay is actually reachable on. It lives in
    /// `config.relayURL` / `config.relayPort` and used to appear nowhere on the
    /// tab named after the relay — "Open Browser" was the only way to find it.
    @ViewBuilder
    private func relayAddressRow(showsMeta: Bool) -> some View {
        if relayManager.isBooting && !relayManager.bootStatusMessage.isEmpty {
            Text(relayManager.bootStatusMessage)
                .font(.appSystem(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 10) {
                Button(action: copyRelayAddress) {
                    HStack(spacing: 5) {
                        Text(configService.config.nostrURL)
                            .font(.appSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: didCopyAddress ? "checkmark" : "doc.on.doc")
                            .font(.appSystem(size: 9, weight: .semibold))
                            .foregroundColor(didCopyAddress ? .havenOnline : .secondary.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(didCopyAddress ? "Copied" : "Copy the relay address")
                #endif
                .accessibilityLabel(Text("Relay address"))
                .accessibilityValue(Text(configService.config.nostrURL))
                .accessibilityHint(Text("Copies the address to the clipboard"))
                .tutorialAnchor(TutorialContent.relayAddress)

                if showsMeta {
                    liveMeta
                }
            }
        }
    }

    @ViewBuilder
    private var liveMeta: some View {
        if relayManager.isRunning {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(liveMetaText(now: context.date))
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
        }
    }

    private var relayControls: some View {
        HStack(spacing: 8) {
            // Stop was reachable from Settings and the menu bar but not from the
            // screen named after the relay.
            if relayManager.isRunning {
                Button {
                    relayManager.stopRelay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .font(.appSystem(size: 11, weight: .bold))
                        Text("Stop")
                            .font(.appSystem(size: 12, weight: .bold))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.platformCardBackground)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.platformCardBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(relayManager.isBooting)
                .accessibilityLabel(Text("Stop relay"))
            }

            Button {
                if relayManager.isRunning {
                    relayManager.stopRelay {
                        relayManager.startRelay(config: configService.config)
                    }
                } else {
                    relayManager.startRelay(config: configService.config)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: relayManager.isRunning ? "arrow.clockwise" : "play.fill")
                        .font(.appSystem(size: 11, weight: .bold))
                    Text(relayManager.isRunning ? "Restart" : "Start Vault")
                        .font(.appSystem(size: 12, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleDark]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(8)
                .opacity(relayManager.isBooting ? 0.4 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(relayManager.isBooting)
            .accessibilityLabel(Text(relayManager.isRunning ? "Restart relay" : "Start relay"))
        }
    }

    /// `isCompact` stacks the controls under the status block. The one-row form
    /// needs roughly 420pt before the address starts truncating, which is wider
    /// than the 380pt sidebar rail.
    func relayStatusHeader(isCompact: Bool) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    statusIndicator

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.appSystem(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .accessibilityLabel(Text("Relay status"))
                            .accessibilityValue(Text(statusTitle))

                        relayAddressRow(showsMeta: !isCompact)

                        if isCompact {
                            liveMeta
                        }
                    }
                    .accessibilityElement(children: .contain)

                    Spacer(minLength: 12)

                    if !isCompact {
                        relayControls
                    }
                }

                if isCompact {
                    relayControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.platformCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                statusColor.opacity(0.35),
                                Color.platformCardBorder,
                                Color.white.opacity(0.02)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: statusColor.opacity(relayManager.isRunning && !relayManager.isBooting ? 0.08 : 0), radius: 10, x: 0, y: 4)
            .animation(Motion.toggle, value: relayManager.isRunning)
            .tutorialAnchor(TutorialContent.relayStatus)

            // Error recovery banner
            if relayManager.isLocked || relayManager.isPortConflict {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(relayManager.isPortConflict ? "Another app is blocking your vault" : "Database lock detected")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                    }

                    Text(relayManager.isPortConflict
                        ? "Another app is in your vault's way. Close other copies of Nostr Vault or restart your computer. The port is under Settings › Advanced."
                        : "A previous session did not shut down cleanly. Clear locks to restart the relay.")
                        .font(.appSystem(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Button {
                            relayManager.forceCleanAndRestart()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("Force Restart")
                            }
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.havenPurple)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        if relayManager.isLocked {
                            Button {
                                relayManager.clearDatabaseLocks { [relayManager, configService] in
                                    Task { @MainActor in
                                        relayManager.startRelay(config: configService.config, isRetry: true)
                                    }
                                }
                            } label: {
                                Text("Clear Locks Only")
                                    .font(.appSystem(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            }
        }
        .padding(.horizontal)
        .onAppear { syncStatusPulse() }
        .onChange(of: relayManager.isRunning) { _, _ in syncStatusPulse() }
        .onChange(of: relayManager.isBooting) { _, _ in syncStatusPulse() }
    }
}
