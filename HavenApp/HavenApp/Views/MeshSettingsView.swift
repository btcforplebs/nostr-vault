#if os(macOS)
import SwiftUI

/// Offers this Mac's relay and Blossom to the FIPS mesh, and shows the address
/// a peer needs in order to reach it.
///
/// Provider only for now: this Mac can be read, it does not yet read anyone
/// else. The consumer half is the Android workstream's.
struct MeshSettingsView: View {
    @ObservedObject private var mesh = FipsMeshService.shared
    @ObservedObject private var configService = ConfigService.shared

    private var relayPort: Int { configService.config.relayPort }

    var body: some View {
        Form {
            Section {
                Text("The mesh lets another Nostr Vault reach this Mac's relay and media directly, without either machine being on the public internet. Your mesh address is separate from your Nostr identity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("Share this Mac on the mesh", isOn: Binding(
                    get: { mesh.isEnabled },
                    set: { mesh.setEnabled($0, relayPort: relayPort) }
                ))
                if mesh.isEnabled {
                    LabeledContent("Relay port offered", value: String(relayPort))
                }
            } header: {
                Text("Mesh")
            } footer: {
                if let error = mesh.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if mesh.status.running {
                Section {
                    // The npub is the whole point of the screen: it is what a
                    // peer dials, and it is not derivable from anything else
                    // shown in the app.
                    LabeledContent("Mesh address") {
                        HStack(spacing: 8) {
                            Text(mesh.status.npub)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(mesh.status.npub, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy mesh address")
                        }
                    }
                    LabeledContent("Mesh IP", value: mesh.status.address)
                        .font(.system(.caption, design: .monospaced))
                    LabeledContent("Exported ports",
                                   value: mesh.status.exportedPorts.isEmpty
                                        ? "none"
                                        : mesh.status.exportedPorts.map(String.init).joined(separator: ", "))
                } header: {
                    Text("This Mac")
                }

                Section {
                    // An endpoint that has reached nothing looks identical to a
                    // working one from the outside, so the peer list is the
                    // only diagnostic worth showing.
                    if mesh.status.peers.isEmpty {
                        Text("No peers yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(mesh.status.peers) { peer in
                            HStack {
                                Image(systemName: peer.connected ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundColor(peer.connected ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(peer.alias ?? String(peer.npub.prefix(20)))
                                        .font(.caption)
                                    if let address = peer.address {
                                        Text(address)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if let rtt = peer.rttMs {
                                    Text("\(rtt) ms")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Peers")
                }
            }
        }
        .onAppear { mesh.refresh() }
    }
}
#endif
