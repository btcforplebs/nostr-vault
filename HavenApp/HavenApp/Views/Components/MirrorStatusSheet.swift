import SwiftUI

struct MirrorStatusSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var mirrorStatus: [String: BlobPresence] = [:]
    @State private var isLoading = true
    @State private var sha256Hash: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView("Checking mirrors...")
                        .padding()
                } else if mirrorStatus.isEmpty {
                    ContentUnavailableView(
                        "No Mirrors Configured",
                        systemImage: "server.rack",
                        description: Text("Configure Blossom mirrors in Settings to enable external backup")
                    )
                } else {
                    List {
                        Section {
                            if let hash = sha256Hash {
                                HStack {
                                    Text("Hash")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(hash.prefix(16) + "...")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Section("Mirror Status") {
                            ForEach(Array(mirrorStatus.keys.sorted()), id: \.self) { mirror in
                                HStack {
                                    Image(systemName: Self.icon(mirrorStatus[mirror]))
                                        .foregroundColor(Self.tint(mirrorStatus[mirror]))

                                    VStack(alignment: .leading, spacing: 2) {
                                        if let host = URL(string: mirror)?.host {
                                            Text(host)
                                                .font(.appSystem(size: 14, weight: .semibold))
                                        }
                                        Text(mirror)
                                            .font(.appSystem(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(Self.label(mirrorStatus[mirror]))
                                        .font(.appSystem(size: 11, weight: .medium))
                                        .foregroundColor(mirrorStatus[mirror] == .present ? .green : .secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Blossom Mirrors")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await checkMirrors()
        }
    }

    private func checkMirrors() async {
        isLoading = true

        // Extract hash from URL
        let lastComponent = url.deletingPathExtension().lastPathComponent
        if lastComponent.count == 64, lastComponent.allSatisfy({ $0.isHexDigit }) {
            sha256Hash = lastComponent

            // Same answer the badges show: re-check through the shared store.
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let store = BlossomBackupStore.shared
            await store.refresh(hash: lastComponent.lowercased(), service: service, force: true)

            await MainActor.run {
                mirrorStatus = store.presence(hash: lastComponent.lowercased()) ?? [:]
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }

    private static func icon(_ presence: BlobPresence?) -> String {
        switch presence {
        case .present: return "checkmark.circle.fill"
        case .unreachable: return "questionmark.circle.fill"
        default: return "xmark.circle.fill"
        }
    }

    private static func tint(_ presence: BlobPresence?) -> Color {
        switch presence {
        case .present: return .green
        case .unreachable: return .orange
        default: return .red
        }
    }

    private static func label(_ presence: BlobPresence?) -> String {
        switch presence {
        case .present: return "Available"
        case .unreachable: return "Couldn't reach"
        default: return "Not Found"
        }
    }
}
