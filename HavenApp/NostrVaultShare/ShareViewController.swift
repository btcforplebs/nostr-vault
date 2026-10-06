import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Share Extension
//
// "Share → Nostr Vault" from any app. The extension does not upload: it copies
// the shared photos and videos into the App Group inbox (NVShareInbox) and
// leaves a notification. The app uploads them from the Media tab when it is
// opened, so the key, the bunker and the device relay never enter this
// process, and a big video does not depend on the sheet staying open.

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.providers = Self.mediaProviders(in: extensionContext)
        model.finish = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }

        let host = UIHostingController(rootView: ShareCard(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private static func mediaProviders(in context: NSExtensionContext?) -> [NSItemProvider] {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        return items
            .flatMap { $0.attachments ?? [] }
            .filter { ShareModel.mediaType(of: $0) != nil }
    }
}

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
            if added > 0 { await Self.notifyReady() }
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
        content.title = "Ready to upload to Blossom"
        content.body = waiting == 1
            ? "1 item is in the upload queue. Tap to finish."
            : "\(waiting) items are in the upload queue. Tap to finish."
        content.userInfo = ["nv_deeplink": NVDeepLink.shareInbox.url.absoluteString]
        let request = UNNotificationRequest(identifier: NVShareInbox.notificationID, content: content, trigger: nil)
        try? await center.add(request)
    }
}

// MARK: - Card

struct ShareCard: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        // Fills the sheet the system presents rather than floating a card in
        // it: the sheet is already the card, and follows light/dark itself.
        VStack(spacing: 16) {
            header
            content
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            Image(systemName: "tray.and.arrow.up.fill")
                .foregroundStyle(Color.accentColor)
            Text("Nostr Vault").font(.headline)
            Spacer()
            if model.phase == .ready {
                Button("Cancel") { model.cancel() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .ready:
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.add()
            } label: {
                Text("Add to Blossom upload queue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.providers.isEmpty)
        case .adding:
            ProgressView("Adding…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        case .added:
            message(
                icon: "checkmark.circle.fill",
                text: "Added to the Blossom upload queue. Open Nostr Vault or tap the notification to finish."
            )
            Button("Done") { model.finish() }
                .frame(maxWidth: .infinity)
        case .failed(let added, let failed):
            message(
                icon: "exclamationmark.triangle.fill",
                text: added == 0
                    ? "Couldn't add \(failed == 1 ? "this item" : "these items")."
                    : "Added \(added). Couldn't add \(failed). Open Nostr Vault or tap the notification to finish."
            )
            Button("Done") { model.finish() }
                .frame(maxWidth: .infinity)
        }
    }

    private func message(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(text).font(.subheadline)
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if model.photoCount > 0 { parts.append(model.photoCount == 1 ? "1 photo" : "\(model.photoCount) photos") }
        if model.videoCount > 0 { parts.append(model.videoCount == 1 ? "1 video" : "\(model.videoCount) videos") }
        return parts.isEmpty ? "Nothing here Nostr Vault can upload." : parts.joined(separator: ", ")
    }
}
