import SwiftUI

// MARK: - Step 3: Relay Configuration

struct RelayConfigStep: View {
    @Binding var relayURL: String
    @Binding var macRelayURL: String
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 20)

            #if os(macOS)
            macOSRelayContent
            #else
            iOSRelayContent
            #endif

            WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: onContinue)

            WizardSkipLink(title: String(localized: "setup.relay.skip")) {
                onSkip()
            }

            Spacer().frame(height: 8)
        }
        .onAppear { appeared = true }
    }

    // MARK: macOS variant
    private var macOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.mac.title"))
                .font(.appSystem(size: 28, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramMac(hasURL: !relayURL.isEmpty)
                .frame(height: 160)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.mac.description1"))
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.mac.description2"))
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.mac.label"), text: $relayURL, placeholder: "relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.mac.hint"))
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }

    // MARK: iOS variant
    private var iOSRelayContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "setup.relay.ios.title"))
                .font(.appSystem(size: 24, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.1), value: appeared)

            // Network diagram
            RelayDiagramiOS(hasURL: !macRelayURL.isEmpty)
                .frame(height: 120)
                .opacity(appeared ? 1 : 0)
                .animation(WizardAnimations.fadeIn.delay(0.3), value: appeared)

            VStack(spacing: 8) {
                Text(String(localized: "setup.relay.ios.description1"))
                    .font(.appSystem(size: 15))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)

                Text(String(localized: "setup.relay.ios.description2"))
                    .font(.appSystem(size: 15, weight: .medium))
                    .foregroundColor(WizardColors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .opacity(appeared ? 1 : 0)
            .animation(WizardAnimations.fadeIn.delay(0.2), value: appeared)

            WizardInputField(label: String(localized: "setup.relay.ios.label"), text: $macRelayURL, placeholder: "wss://relay.yourdomain.com")
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)
                .animation(WizardAnimations.springEnter.delay(0.4), value: appeared)

            Text(String(localized: "setup.relay.ios.hint"))
                .font(.appSystem(size: 12))
                .foregroundColor(WizardColors.textMuted)
        }
    }
}

// MARK: - Relay Diagrams

private struct RelayDiagramMac: View {
    let hasURL: Bool
    @State private var particlePhase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let centerX = size.width / 2
                let centerY = size.height / 2

                // Mac icon position
                let macX = centerX - 80
                let macY = centerY

                // Relay position
                let relayX = centerX
                let relayY = centerY + 40

                // Network position
                let netX = centerX + 100
                let netY = centerY - 10

                // Draw connection lines
                drawLine(context: context, from: CGPoint(x: macX, y: macY), to: CGPoint(x: relayX, y: relayY), color: WizardColors.accentPrimary.opacity(0.4))
                drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: netX, y: netY), color: WizardColors.accentPrimary.opacity(0.3))

                // Draw flowing particle
                let particleT = fmod(t * 0.3, 1.0)
                let px = macX + (netX - macX) * particleT
                let py = macY + (netY - macY) * particleT
                let particleRect = CGRect(x: px - 3, y: py - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: particleRect), with: .color(WizardColors.accentPrimary))

                // Globe connection when URL entered
                if hasURL {
                    let globeX = relayX
                    let globeY = centerY - 40
                    drawLine(context: context, from: CGPoint(x: relayX, y: relayY), to: CGPoint(x: globeX, y: globeY), color: WizardColors.accentPrimary.opacity(0.3))
                }

                // Network dots
                for i in 0..<6 {
                    let angle = Double(i) * (.pi * 2.0 / 6.0) + t * 0.05
                    let dx = netX + cos(angle) * 25
                    let dy = netY + sin(angle) * 25
                    let brightness = 0.3 + 0.2 * sin(t * 0.5 + Double(i))
                    let dotRect = CGRect(x: dx - 3, y: dy - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dotRect), with: .color(WizardColors.textMuted.opacity(brightness)))
                }
            }
            .overlay {
                // SF Symbol overlays
                VStack {
                    HStack(spacing: 80) {
                        VStack(spacing: 4) {
                            Image(systemName: "laptopcomputer")
                                .font(.appSystem(size: 32))
                                .foregroundColor(WizardColors.textPrimary)
                                .shadow(color: WizardColors.accentGlow, radius: 6)
                            Text(String(localized: "setup.relay.diagram.mac"))
                                .font(.appSystem(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -8)

                        VStack(spacing: 4) {
                            Image(systemName: "network")
                                .font(.appSystem(size: 24))
                                .foregroundColor(WizardColors.textMuted)
                            Text(String(localized: "setup.relay.diagram.network"))
                                .font(.appSystem(size: 11))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -20)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.appSystem(size: 16))
                            .foregroundColor(WizardColors.accentPrimary)
                        Text(String(localized: "setup.relay.diagram.relay"))
                            .font(.appSystem(size: 11))
                            .foregroundColor(WizardColors.accentPrimary)
                    }
                    .offset(y: 8)

                    if hasURL {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.appSystem(size: 14))
                                .foregroundColor(WizardColors.accentPrimary.opacity(0.7))
                            Text(String(localized: "setup.relay.diagram.public"))
                                .font(.appSystem(size: 10))
                                .foregroundColor(WizardColors.textMuted)
                        }
                        .offset(y: -50)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func drawLine(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }
}

private struct RelayDiagramiOS: View {
    let hasURL: Bool

    var body: some View {
        HStack(spacing: 0) {
            // iPhone
            VStack(spacing: 4) {
                Image(systemName: "iphone")
                    .font(.appSystem(size: 28))
                    .foregroundColor(WizardColors.textPrimary)
                Text(String(localized: "setup.relay.diagram.iphone"))
                    .font(.appSystem(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }

            // Connection line
            VStack(spacing: 2) {
                Rectangle()
                    .fill(hasURL ? WizardColors.accentPrimary.opacity(0.5) : WizardColors.textMuted.opacity(0.3))
                    .frame(height: 2)
                    .overlay {
                        if !hasURL {
                            // Dashed line
                            Rectangle()
                                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                .foregroundColor(WizardColors.textMuted.opacity(0.4))
                        }
                    }
                if !hasURL {
                    Text("?")
                        .font(.appSystem(size: 10, weight: .bold))
                        .foregroundColor(WizardColors.textMuted)
                }
            }
            .frame(width: 60)

            // Mac + Relay
            VStack(spacing: 4) {
                Image(systemName: "laptopcomputer")
                    .font(.appSystem(size: 28))
                    .foregroundColor(hasURL ? WizardColors.textPrimary : WizardColors.textMuted)
                    .shadow(color: hasURL ? WizardColors.accentGlow : .clear, radius: 4)
                HStack(spacing: 2) {
                    Image(systemName: "server.rack")
                        .font(.appSystem(size: 10))
                    Text(String(localized: "setup.relay.diagram.macRelay"))
                        .font(.appSystem(size: 11))
                }
                .foregroundColor(hasURL ? WizardColors.accentPrimary : WizardColors.textMuted)
            }

            // Connection to network
            Rectangle()
                .fill(WizardColors.textMuted.opacity(0.3))
                .frame(width: 40, height: 2)

            // Network
            VStack(spacing: 4) {
                Image(systemName: "network")
                    .font(.appSystem(size: 24))
                    .foregroundColor(WizardColors.textMuted)
                Text(String(localized: "setup.relay.diagram.nostr"))
                    .font(.appSystem(size: 11))
                    .foregroundColor(WizardColors.textMuted)
            }
        }
        .padding(.vertical, 16)
    }
}
