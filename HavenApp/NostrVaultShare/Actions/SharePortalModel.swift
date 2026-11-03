import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Portal model
//
// Everything that is not a plain photo/video share: read the input, rank the
// actions, let the person pick one and fill its form, then write a share
// intent (NVShareQueue) and leave a notification. Nothing is signed or sent
// from here; the app's review card does that.

@MainActor
final class SharePortalModel: ObservableObject {
    enum Phase: Equatable {
        case reading
        case choosing
        case form(NVShareAction)
        case queueing
        case queued(NVShareAction)
        case failed
    }

    @Published var phase: Phase = .reading
    @Published private(set) var input = NVShareInput()
    @Published private(set) var offered: [NVShareAction] = []
    @Published var account: String?
    private(set) var accounts: [NVShareAccountsSnapshot.Account] = []
    private var read = ShareInputReader.Result()

    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    func load(_ items: [NSExtensionItem]) {
        Task {
            read = await ShareInputReader.read(items)
            input = read.input
            offered = NVShareActionAvailability.offered(NVShareClassifier.classify(input))
            if let snapshot = NVShareAccountsSnapshot.read() {
                accounts = snapshot.accounts
                account = snapshot.active.isEmpty ? nil : snapshot.active
            }
            phase = .choosing
        }
    }

    func pick(_ action: NVShareAction) {
        switch action {
        case .highlight: phase = .form(.highlight)
        default: queue(action, form: [:])
        }
    }

    /// Writes the intent. Files are copied only for actions that use them.
    func queue(_ action: NVShareAction, form: [String: String]) {
        guard phase != .queueing else { return }
        phase = .queueing
        let source = NVShareIntent.Source(url: NVShareClassifier.webURL(of: input), title: input.title,
                                          text: input.text, selection: input.selection,
                                          app: read.fromSafariPage ? "com.apple.mobilesafari" : nil,
                                          ldTypes: input.ldTypes)
        let intent = NVShareIntent(account: account, action: action, source: source, form: form)
        let files = Self.takesFiles(action) ? read.files : []
        Task {
            let ok = await Self.write(intent, files: files)
            guard ok else { phase = .failed; return }
            await Self.notify(action)
            phase = .queued(action)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            finish()
        }
    }

    static func takesFiles(_ action: NVShareAction) -> Bool {
        [.privateCopy, .calendar, .dm, .mediaPost].contains(action)
    }

    nonisolated private static func write(_ intent: NVShareIntent, files: [(provider: NSItemProvider, type: UTType)]) async -> Bool {
        guard let queue = NVShareQueue.shared else { return false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("portal-\(intent.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var attachments: [NVShareQueue.Attachment] = []
        for file in files {
            guard let copy = await ShareInputReader.copyFile(file.provider, type: file.type, to: tmp) else { return false }
            let ext = file.type.preferredFilenameExtension ?? copy.pathExtension
            let name = file.provider.suggestedName.map { ($0 as NSString).pathExtension.isEmpty ? "\($0).\(ext)" : $0 } ?? "shared.\(ext)"
            attachments.append(.init(source: copy, name: name, mime: file.type.preferredMIMEType ?? "application/octet-stream"))
        }
        return (try? queue.add(intent, attachments: attachments)) != nil
    }

    /// One banner for the portal, replaced by the next share. With
    /// notifications off there is no banner; opening the app still finds it.
    nonisolated private static func notify(_ action: NVShareAction) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Ready in Nostr Vault"
        content.body = "\(action.title): tap to review it. Nothing is posted until you do."
        content.userInfo = ["nv_deeplink": NVDeepLink.sharePortal.url.absoluteString]
        try? await center.add(UNNotificationRequest(identifier: NVShareQueue.notificationID, content: content, trigger: nil))
    }
}
