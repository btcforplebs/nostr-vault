import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Model

@MainActor
final class ShareModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case adding
        case added(Int)
        case failed(added: Int, failed: Int)
    }

    @Published var phase: Phase = .ready
    var providers: [NSItemProvider] = []
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    var photoCount: Int { providers.filter { Self.mediaType(of: $0)?.conforms(to: .movie) == false }.count }
    var videoCount: Int { providers.count - photoCount }

    /// The first registered type that is a video or an image, video first:
    /// a Live Photo or a clip from some apps also offers a still frame.
    nonisolated static func mediaType(of provider: NSItemProvider) -> UTType? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        return types.first { $0.conforms(to: .movie) } ?? types.first { $0.conforms(to: .image) }
    }

    func add() {
        guard phase == .ready else { return }
        phase = .adding
        let providers = self.providers
        Task {
            var added = 0
            for provider in providers {
                if await Self.copyToInbox(provider) { added += 1 }
            }
            let failed = providers.count - added
            if added > 0 {
                // The Share Portal's `upload` action. Its files stay in
                // NVShareInbox, so the app's upload path is the same one.
                Self.queueUploadIntent(count: added)
                await Self.notifyReady()
            }
            phase = failed == 0 ? .added(added) : .failed(added: added, failed: failed)
            if failed == 0 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                finish()
            }
        }
    }

    /// Copies one shared item into the inbox. Files are copied, never loaded
    /// into memory: an extension has a hard memory ceiling and a video does
    /// not fit under it.
    nonisolated private static func copyToInbox(_ provider: NSItemProvider) async -> Bool {
        guard let type = mediaType(of: provider) else { return false }
        let name = provider.suggestedName ?? (type.conforms(to: .movie) ? "video" : "photo")
        let ext = type.preferredFilenameExtension ?? (type.conforms(to: .movie) ? "mov" : "jpg")
        let preferred = (name as NSString).pathExtension.isEmpty ? "\(name).\(ext)" : name

        if await copyFileRepresentation(provider, type: type, preferredName: preferred) { return true }
        // Some apps share an in-memory image (a screenshot, an edited photo)
        // with no file behind it. Small enough to take as data.
        guard type.conforms(to: .image) else { return false }
        return await copyDataRepresentation(provider, type: type, preferredName: preferred)
    }

    nonisolated private static func copyFileRepresentation(_ provider: NSItemProvider, type: UTType, preferredName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // The provided file is deleted as soon as this handler returns.
                guard let url else { continuation.resume(returning: false); return }
                let ok = (try? NVShareInbox.add(fileAt: url, preferredName: preferredName)) != nil
                continuation.resume(returning: ok)
            }
        }
    }

    nonisolated private static func copyDataRepresentation(_ provider: NSItemProvider, type: UTType, preferredName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { continuation.resume(returning: false); return }
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((preferredName as NSString).pathExtension)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let ok = (try? data.write(to: tmp)) != nil
                    && (try? NVShareInbox.add(fileAt: tmp, preferredName: preferredName)) != nil
                continuation.resume(returning: ok)
            }
        }
    }

    nonisolated private static func queueUploadIntent(count: Int) {
        try? NVShareQueue.shared?.add(NVShareIntent(action: .upload, form: ["count": String(count)]))
    }

    /// One notification for everything waiting, replaced on each share. If
    /// notifications are off there is simply no banner: opening the app
    /// still finishes the upload.
    nonisolated private static func notifyReady() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let waiting = NVShareInbox.pending().count
        let content = UNMutableNotificationContent()
        content.title = "Ready to upload to your media servers"
        content.body = waiting == 1
            ? "1 item is in the upload queue. Tap to finish."
            : "\(waiting) items are in the upload queue. Tap to finish."
        content.userInfo = ["nv_deeplink": NVDeepLink.shareInbox.url.absoluteString]
        let request = UNNotificationRequest(identifier: NVShareInbox.notificationID, content: content, trigger: nil)
        try? await center.add(request)
    }
}
