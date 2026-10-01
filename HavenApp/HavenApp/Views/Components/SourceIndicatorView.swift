import SwiftUI

struct SourceIndicatorView: View {
    let url: URL
    var onMirrorComplete: (() -> Void)? = nil
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @State private var source: MediaCacheService.MediaSource = .remote
    @State private var isCaching = false
    @State private var isMirroring = false
    @State private var showMirrorStatus = false
    @State private var isPushing = false
    @State private var didPush = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: source.icon)
                Text(source.rawValue)
                    .font(.appSystem(size: 11, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(source.color.opacity(0.2))
            .foregroundColor(source.color)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(source.color.opacity(0.3), lineWidth: 1)
            )
            .onTapGesture {
                if source == .blossom {
                    showMirrorStatus = true
                }
            }

            if source == .remote {
                Button(action: cacheMedia) {
                    if isCaching {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Cache Locally", systemImage: "square.and.arrow.down")
                            .font(.appSystem(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCaching)
            }

            if source == .cached && configService.hasExternalShareURL(for: URL(string: "https://localhost")!) {
                Button(action: mirrorToBlossom) {
                    if isMirroring {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("Mirror to Blossom", systemImage: "arrow.down.circle")
                            .font(.appSystem(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isMirroring)
            }

            // A blob that lives on this device's own relay: copy it out to the
            // user's outside Blossom servers. This was only reachable from the
            // grid's long-press menu, so the viewer had no way to do it.
            if source == .blossom && !configService.config.activeBlossomMirrors.isEmpty {
                Button(action: pushToMirrors) {
                    if isPushing {
                        ProgressView().controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else if didPush {
                        Label("Mirrored", systemImage: "checkmark.icloud")
                            .font(.appSystem(size: 11, weight: .bold))
                    } else {
                        Label("Mirror to Blossom", systemImage: "arrow.up.circle")
                            .font(.appSystem(size: 11, weight: .bold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isPushing || didPush)
            }
        }
        .onAppear {
            updateSource()
        }
        .sheet(isPresented: $showMirrorStatus) {
            MirrorStatusSheet(url: url)
                .environmentObject(configService)
                .environmentObject(nostrService)
        }
    }

    private func updateSource() {
        source = MediaCacheService.shared.getSource(for: url)
    }

    private func cacheMedia() {
        isCaching = true
        MediaSessionService.shared.session.dataTask(with: url) { data, response, _ in
            if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                MediaCacheService.shared.saveToCache(url: url, data: data)
                DispatchQueue.main.async {
                    source = .cached
                    isCaching = false
                }
            } else {
                DispatchQueue.main.async {
                    isCaching = false
                }
            }
        }.resume()
    }

    private func pushToMirrors() {
        let sha256 = url.deletingPathExtension().lastPathComponent
        guard sha256.count == 64 && sha256.allSatisfy({ $0.isHexDigit }) else {
            ErrorNotificationManager.shared.show(
                String(localized: "media.push.error.noHash"),
                icon: "exclamationmark.icloud.fill",
                style: .warning
            )
            return
        }
        isPushing = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.pushLocalToMirrors(sha256: sha256)
            await MainActor.run {
                isPushing = false
                if success {
                    didPush = true
                    ActionToastManager.shared.show(
                        icon: "icloud.and.arrow.up.fill",
                        message: String(localized: "media.push.succeeded"),
                        color: Color.havenVerified
                    )
                    onMirrorComplete?()
                } else {
                    ErrorNotificationManager.shared.show(
                        String(localized: "media.push.failed"),
                        icon: "exclamationmark.icloud.fill"
                    )
                }
            }
        }
    }

    private func mirrorToBlossom() {
        isMirroring = true
        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            let success = await service.downloadFromURL(url: url, mirrorToExternal: true)
            await MainActor.run {
                isMirroring = false
                if success {
                    source = .blossom
                    onMirrorComplete?()
                }
            }
        }
    }
}
