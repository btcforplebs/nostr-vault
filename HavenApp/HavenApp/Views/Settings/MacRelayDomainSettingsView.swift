import SwiftUI

#if os(macOS)
/// macOS settings page for configuring the relay domain, port, and Cloudflare tunnel.
struct MacRelayDomainSettingsView: View {
    @EnvironmentObject var configService: ConfigService

    var body: some View {
        Form {
            // MARK: - Domain
            Section {
                CommitOnEndTextField("relay.yourdomain.com", text: $configService.config.relayURL)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)

                if !configService.config.sanitizedRelayURL.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.havenOnline)
                                .font(.appCaption)
                            Text("wss://\(configService.config.sanitizedRelayURL)")
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.havenOnline)
                                .font(.appCaption)
                            Text("https://\(configService.config.sanitizedRelayURL)")
                                .font(.appSystem(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                }
            } header: {
                Text("Relay Domain").settingInfo(.relayDomain)
            }

            // MARK: - Port
            Section {
                HStack {
                    Text("Port").settingInfo(.relayPort)
                    Spacer()
                    CommitOnEndTextField("3355", text: Binding(
                        get: { String(configService.config.relayPort) },
                        // A value that isn't a port is dropped; the field
                        // snaps back to the port in use.
                        set: { if let port = Int($0), (1...65535).contains(port) { configService.config.relayPort = port } }
                    ))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Network")
            }

            // MARK: - Cloudflare Tunnel Instructions
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    instructionStep(1, "Install cloudflared",
                        "brew install cloudflared")
                    instructionStep(2, "Authenticate with Cloudflare",
                        "cloudflared tunnel login")
                    instructionStep(3, "Create a tunnel",
                        "cloudflared tunnel create haven")
                    instructionStep(4, "Route your domain to the tunnel",
                        "cloudflared tunnel route dns haven \(configService.config.sanitizedRelayURL.isEmpty ? "relay.yourdomain.com" : configService.config.sanitizedRelayURL)")
                    instructionStep(5, "Run the tunnel",
                        "cloudflared tunnel run --url http://localhost:\(configService.config.relayPort) haven")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Cloudflare Tunnel Setup")
            } footer: {
                Text("To keep the tunnel running in the background, use `brew services start cloudflared` or add it to your login items.")
            }
        }
        .groupedFormStyleCompat()
    }

    private func instructionStep(_ number: Int, _ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(title)")
                .font(.appSubheadline.bold())
            HStack {
                Text(command)
                    .font(.appSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.appSystem(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }
        }
    }
}
#endif
