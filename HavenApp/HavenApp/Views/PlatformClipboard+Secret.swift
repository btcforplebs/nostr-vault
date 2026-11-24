import Foundation
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension PlatformClipboard {
    /// How long a copied private key stays on the clipboard.
    static let secretLifetime: TimeInterval = 60

    /// Copies an nsec or ncryptsec. On iOS it stays on this device (no
    /// Universal Clipboard to your other Apple devices) and expires after
    /// `secretLifetime`. On the Mac, which has neither option, the clipboard
    /// is cleared after `secretLifetime` unless something else was copied since,
    /// and the copy is marked concealed and transient (nspasteboard.org) so
    /// clipboard-history apps skip it. Universal Clipboard may still carry it.
    @MainActor
    static func copySecret(_ secret: String) {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: concealedType)
        pasteboard.setString("", forType: transientType)
        let copied = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + secretLifetime) {
            guard pasteboard.changeCount == copied else { return }
            pasteboard.clearContents()
        }
        #elseif canImport(UIKit)
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(secretLifetime)]
        )
        #endif
    }

    #if canImport(AppKit)
    /// Markers clipboard managers honour (http://nspasteboard.org).
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    #endif
}
