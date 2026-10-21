import SwiftUI

/// How media is played and kept on this device. App-side only: none of this
/// reaches the relay, which is why it no longer sits in Advanced next to the
/// relay's database.
struct MediaSettingsView: View {
    @EnvironmentObject var configService: ConfigService
    @State private var cacheBytes: Int64? = nil
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $configService.config.autoplayVideos) {
                    Text("Autoplay Videos").settingInfo(.mediaAutoplay)
                }
                Toggle(isOn: $configService.config.prefetchProfilePictures) {
                    Text("Prefetch Profile Pictures").settingInfo(.mediaPrefetchAvatars)
                }
            } header: {
                Text("Playback")
            }

            Section {
                Toggle(isOn: $configService.config.disableMediaCache) {
                    Text("Disable Media Cache").settingInfo(.mediaDisableCache)
                }
                Picker(selection: $configService.config.cacheTTLDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                } label: {
                    Text("Keep Media For").settingInfo(.mediaCacheTTL)
                }
                .disabled(configService.config.disableMediaCache)

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    HStack {
                        Label("Clear Media Cache", systemImage: "trash")
                        Spacer()
                        if let cacheBytes {
                            Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .settingInfo(.mediaClearCache)
            } header: {
                Text("Cache")
            }
        }
        .task { await measureCache() }
        .alert("Clear Media Cache?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text(Self.clearMessage(cacheBytes))
        }
        .groupedFormStyleCompat()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    static func clearMessage(_ bytes: Int64?) -> String {
        let size = bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " of " } ?? ""
        return "Removes \(size)temporary copies of images and videos. They download again when you view them. Your vault and your Blossom servers are not touched."
    }

    private func measureCache() async {
        let bytes = await Task.detached(priority: .utility) { MediaCacheService.shared.cacheSizeBytes() }.value
        cacheBytes = bytes
    }

    private func clearCache() {
        Task {
            let result = await Task.detached(priority: .userInitiated) { MediaCacheService.shared.clearCache() }.value
            let freed = ByteCountFormatter.string(fromByteCount: result.bytesFreed, countStyle: .file)
            if result.filesFailed == 0 {
                ActionToastManager.shared.show(icon: "trash.fill", message: "Cleared \(freed) of temporary copies", tone: .success)
            } else {
                ErrorNotificationManager.shared.show("Cleared \(freed), but \(result.filesFailed) files could not be removed", icon: "exclamationmark.triangle.fill", style: .warning)
            }
            await measureCache()
        }
    }
}
