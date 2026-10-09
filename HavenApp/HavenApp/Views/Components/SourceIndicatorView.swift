import SwiftUI

// MARK: - Blossom backup status (shared)

/// How many of the user's Blossom servers hold one file. The viewer, the list
/// row and the grid tile all read this one answer, so a file can no longer be
/// "Available" in one place and offered a Mirror button in another.
struct BlossomBackupSummary: Equatable {
    let present: Int
    let unreachable: Int
    let total: Int
    /// Configured servers not known to have the file: those that said no,
    /// plus those that could not be asked. Uploads go only to these.
    let missing: [String]

    var isComplete: Bool { total > 0 && present == total }
    /// Worth offering an upload: some server lacks it, or could not be asked.
    var needsMirror: Bool { total > 0 && present < total }
}

/// Per-hash results of asking each Blossom server, kept for the session and
/// refreshed after any action that changes them.
@MainActor
final class BlossomBackupStore: ObservableObject {
    static let shared = BlossomBackupStore()

    @Published private var results: [String: [String: BlobPresence]] = [:]
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Each server's answer for `hash`, nil until checked.
    func presence(hash: String) -> [String: BlobPresence]? { results[hash] }

    /// nil until the first check for this hash has finished.
    func summary(hash: String, mirrors: [String]) -> BlossomBackupSummary? {
        guard !mirrors.isEmpty else { return BlossomBackupSummary(present: 0, unreachable: 0, total: 0, missing: []) }
        guard let byMirror = results[hash] else { return nil }
        // A server added since the last check has no answer yet: treat the
        // whole summary as unknown rather than guessing.
        guard mirrors.allSatisfy({ byMirror[$0] != nil }) else { return nil }
        var present = 0, unreachable = 0
        var missing: [String] = []
        for mirror in mirrors {
            switch byMirror[mirror] {
            case .present: present += 1
            case .unreachable: unreachable += 1; missing.append(mirror)
            default: missing.append(mirror)
            }
        }
        return BlossomBackupSummary(present: present, unreachable: unreachable, total: mirrors.count, missing: missing)
    }

    /// Checks the servers for `hash`. Without `force`, a cached answer or a
    /// check already running is reused. With `force`, it waits for any
    /// running check and then asks again, so the caller reads a fresh answer.
    func refresh(hash: String, service: BlossomService, force: Bool = false) async {
        if let running = inFlight[hash] {
            await running.value
            if !force { return }
        } else if !force, results[hash] != nil {
            return
        }
        let task = Task { @MainActor in
            let presence = await service.checkMirrorPresence(sha256: hash)
            self.results[hash] = presence
        }
        inFlight[hash] = task
        await task.value
        if inFlight[hash] == task { inFlight[hash] = nil }
    }
}

/// The cloud "x/y" badge: green on every server, orange on some, grey on
/// none, "?" when a server could not be asked.
struct BlossomBackupBadge: View {
    let hash: String
    var compact = false
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var store = BlossomBackupStore.shared

    var body: some View {
        let mirrors = configService.config.activeBlossomMirrors
        Group {
            if !mirrors.isEmpty {
                let summary = store.summary(hash: hash, mirrors: mirrors)
                HStack(spacing: 3) {
                    Image(systemName: summary?.isComplete == true ? "checkmark.icloud.fill" : "icloud.fill")
                        .font(.appSystem(size: compact ? 9 : 11))
                    Text(Self.text(summary, total: mirrors.count))
                        .font(.appSystem(size: compact ? 10 : 12, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundColor(Self.tint(summary))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.accessibility(summary, total: mirrors.count))
            }
        }
        // Keyed on the server list too: adding a server asks again instead of
        // leaving the count unknown.
        .task(id: hash + "|" + configService.config.activeBlossomMirrors.joined(separator: ",")) {
            let mirrors = configService.config.activeBlossomMirrors
            guard !mirrors.isEmpty else { return }
            await store.refresh(hash: hash,
                                service: BlossomService(configService: configService, nostrService: nostrService),
                                force: store.summary(hash: hash, mirrors: mirrors) == nil)
        }
    }

    static func text(_ summary: BlossomBackupSummary?, total: Int) -> String {
        guard let summary else { return "–/\(total)" }
        return summary.unreachable > 0 && summary.present < summary.total
            ? "\(summary.present)/\(total)?"
            : "\(summary.present)/\(total)"
    }

    static func tint(_ summary: BlossomBackupSummary?) -> Color {
        guard let summary, summary.present > 0 else { return .secondary }
        return summary.isComplete ? .green : .orange
    }

    static func accessibility(_ summary: BlossomBackupSummary?, total: Int) -> String {
        guard let summary else { return "Checking your Blossom servers" }
        var text = "On \(summary.present) of \(total) Blossom servers"
        if summary.unreachable > 0 { text += ", \(summary.unreachable) could not be reached" }
        return text
    }
}

/// The two backup actions, shared by the viewer, the list row and the grid
/// tile so they behave the same everywhere.
@MainActor
enum MediaBackupActions {
    /// Uploads a file already in the vault to the servers not known to have
    /// it, then re-checks so the badge shows the new count.
    static func mirrorMissing(hash: String, configService: ConfigService, nostrService: NostrService) async -> Bool {
        let service = BlossomService(configService: configService, nostrService: nostrService)
        let store = BlossomBackupStore.shared
        await store.refresh(hash: hash, service: service, force: true)
        let mirrors = configService.config.activeBlossomMirrors
        guard let summary = store.summary(hash: hash, mirrors: mirrors) else { return false }
        guard summary.needsMirror else { return true }
        let ok = await service.pushLocalToMirrors(sha256: hash, only: summary.missing)
        await store.refresh(hash: hash, service: service, force: true)
        return ok
    }

    enum SaveOutcome { case failed, savedOnly, savedAndBackedUp }

    /// Stores the file in the vault on this phone, then uploads it to any of
    /// the user's Blossom servers that do not have it yet.
    static func saveToVault(url: URL, configService: ConfigService, nostrService: NostrService) async -> SaveOutcome {
        let service = BlossomService(configService: configService, nostrService: nostrService)
        guard await service.downloadFromURL(url: url, mirrorToExternal: false) else { return .failed }
        guard let hash = MediaCacheService.blossomHash(in: url),
              !configService.config.activeBlossomMirrors.isEmpty else { return .savedOnly }
        return await mirrorMissing(hash: hash, configService: configService, nostrService: nostrService)
            ? .savedAndBackedUp : .savedOnly
    }

    static func announce(_ outcome: SaveOutcome) {
        switch outcome {
        case .failed:
            ErrorNotificationManager.shared.show(String(localized: "media.mirror.failed"), icon: "exclamationmark.icloud.fill")
        case .savedOnly:
            ActionToastManager.shared.show(icon: "internaldrive.fill", message: "Saved to your vault on this phone", color: Color.havenVerified)
        case .savedAndBackedUp:
            ActionToastManager.shared.show(icon: "internaldrive.fill", message: "Saved to your vault and your Blossom", color: Color.havenVerified)
        }
    }

    static func announceMirror(_ ok: Bool) {
        if ok {
            ActionToastManager.shared.show(icon: "icloud.and.arrow.up.fill", message: String(localized: "media.push.succeeded"), color: Color.havenVerified)
        } else {
            ErrorNotificationManager.shared.show(String(localized: "media.push.failed"), icon: "exclamationmark.icloud.fill")
        }
    }
}

// MARK: - Viewer badge and actions

struct SourceIndicatorView: View {
    let url: URL
    var onMirrorComplete: (() -> Void)? = nil
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var nostrService: NostrService
    @ObservedObject private var backupStore = BlossomBackupStore.shared
    @State private var source: MediaCacheService.MediaSource = .remote
    @State private var isCaching = false
    @State private var isSavingToVault = false
    @State private var showMirrorStatus = false
    @State private var isPushing = false

    private var hash: String? { MediaCacheService.blossomHash(in: url) }

    var body: some View {
        let mirrors = configService.config.activeBlossomMirrors
        let summary = hash.flatMap { backupStore.summary(hash: $0, mirrors: mirrors) }

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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

                if let hash, !mirrors.isEmpty {
                    Button {
                        showMirrorStatus = true
                    } label: {
                        BlossomBackupBadge(hash: hash)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                }
            }

            switch source {
            case .blossom:
                // On the phone: offer an upload only where it is missing.
                if let summary, summary.needsMirror {
                    Button(action: pushToMirrors) {
                        if isPushing {
                            ProgressView().controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("Mirror to Blossom", systemImage: "arrow.up.circle")
                                .font(.appSystem(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isPushing)
                    if summary.unreachable > 0 {
                        Text(summary.unreachable == 1 ? "Couldn't reach 1 server" : "Couldn't reach \(summary.unreachable) servers")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
            case .cached, .remote:
                HStack(spacing: 8) {
                    Button(action: saveToVault) {
                        if isSavingToVault {
                            ProgressView().controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Label("Save to Vault", systemImage: "internaldrive")
                                .font(.appSystem(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSavingToVault)

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
                }
            }
        }
        .onAppear {
            updateSource()
        }
        .onChange(of: url) { _, _ in
            updateSource()
        }
        .onReceive(NotificationCenter.default.publisher(for: .havenMediaCacheCleared)) { _ in
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

    private func saveToVault() {
        isSavingToVault = true
        Task { @MainActor in
            let outcome = await MediaBackupActions.saveToVault(url: url, configService: configService, nostrService: nostrService)
            isSavingToVault = false
            updateSource()
            MediaBackupActions.announce(outcome)
            if outcome != .failed { onMirrorComplete?() }
        }
    }

    private func pushToMirrors() {
        guard let hash else {
            ErrorNotificationManager.shared.show(
                String(localized: "media.push.error.noHash"),
                icon: "exclamationmark.icloud.fill",
                style: .warning
            )
            return
        }
        isPushing = true
        Task { @MainActor in
            let ok = await MediaBackupActions.mirrorMissing(hash: hash, configService: configService, nostrService: nostrService)
            isPushing = false
            MediaBackupActions.announceMirror(ok)
            if ok { onMirrorComplete?() }
        }
    }
}
