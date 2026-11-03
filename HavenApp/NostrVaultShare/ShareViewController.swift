import SwiftUI
import UIKit

// MARK: - Share Extension
//
// "Share → Nostr Vault" from any app. The extension does not upload: it copies
// the shared photos and videos into the App Group inbox (NVShareInbox) and
// leaves a notification. The app uploads them from the Media tab when it is
// opened, so the key, the bunker and the device relay never enter this
// process, and a big video does not depend on the sheet staying open.

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    private let portal = SharePortalModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let finish: () -> Void = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let cancel: () -> Void = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }

        // Photos and videos and nothing else keep today's card exactly. Any
        // link, text, page or other file goes to the Share Portal.
        let root: AnyView
        if Self.isMediaOnly(extensionContext) {
            model.providers = Self.mediaProviders(in: extensionContext)
            model.finish = finish
            model.cancel = cancel
            root = AnyView(ShareCard(model: model))
        } else {
            portal.finish = finish
            portal.cancel = cancel
            portal.load(extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            root = AnyView(SharePortalCard(model: portal))
        }

        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private static func isMediaOnly(_ context: NSExtensionContext?) -> Bool {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        return !attachments.isEmpty && attachments.allSatisfy { ShareModel.mediaType(of: $0) != nil }
    }

    private static func mediaProviders(in context: NSExtensionContext?) -> [NSItemProvider] {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        return items
            .flatMap { $0.attachments ?? [] }
            .filter { ShareModel.mediaType(of: $0) != nil }
    }
}
