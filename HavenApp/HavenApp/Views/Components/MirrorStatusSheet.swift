import SwiftUI

struct MirrorStatusSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService

    @State private var mirrorStatus: [String: BlobPresence] = [:]
    @State private var isLoading = true
    @State private var sha256Hash: String?
    /// The file in this phone's vault, when it is there to copy from.
    @State private var localFile: URL?
    @State private var isCopying = false
    /// What the last copy said, per server, until the next check.
    @State private var copyResults: [String: BlobCopyOutcome] = [:]

    private var missingServers: [String] {
        mirrorStatus.keys.filter { mirrorStatus[$0] == .absent }.sorted()
    }

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
                        description: Text("Add media servers in Settings to keep copies of your media")
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
                                VStack(alignment: .leading, spacing: 4) {
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
                                    if case .failed(let reason) = copyResults[mirror] {
                                        Text(reason)
                                            .font(.appSystem(size: 12))
                                            .foregroundColor(.red)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        if localFile != nil, !missingServers.isEmpty {
                            Section {
                                Button {
                                    Task { await copyToMissing() }
                                } label: {
                                    HStack {
                                        Text(copyResults.isEmpty ? copyTitle : "Retry")
                                        Spacer()
                                        if isCopying { ProgressView().controlSize(.small) }
                                    }
                                }
                                .disabled(isCopying)
                            } footer: {
                                Text("This file is on this phone. Copying sends it to the servers that don't have it.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Media Servers")
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

    private var copyTitle: String {
        missingServers.count == 1 ? "Copy to \(URL(string: missingServers[0])?.host ?? "server")"
            : "Copy to \(missingServers.count) servers"
    }

    private func copyToMissing() async {
        guard let hash = sha256Hash?.lowercased(), let file = localFile else { return }
        isCopying = true
        let service = BlossomService(configService: configService, nostrService: nostrService)
        let results = await service.copyStoredBlob(sha256: hash, fileURL: file, to: missingServers)
        let copied = results.compactMap { $0.value == .copied ? $0.key : nil }
        if !copied.isEmpty {
            BlossomBackupStore.shared.record(hash: hash, presence: Dictionary(uniqueKeysWithValues: copied.map { ($0, .present) }))
        }
        for server in copied { mirrorStatus[server] = .present }
        copyResults = results.filter { $0.value != .copied }
        isCopying = false
    }

    /// The vault keeps a blob under its hash, sometimes with an extension.
    private func findLocalFile(hash: String) async -> URL? {
        let dir = configService.relayDataDir.appendingPathComponent(configService.config.blossomPath)
        return await Task.detached(priority: .userInitiated) {
            let plain = dir.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: plain.path) { return plain }
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.first { $0.deletingPathExtension().lastPathComponent.lowercased() == hash }
        }.value
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

            let file = await findLocalFile(hash: lastComponent.lowercased())
            await MainActor.run {
                mirrorStatus = store.presence(hash: lastComponent.lowercased()) ?? [:]
                localFile = file
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
