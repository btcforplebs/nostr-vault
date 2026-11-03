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
