import Foundation

/// What the media delete confirmation says, word for word the same as
/// Android's `DeleteBlobConfirmDialog` (one wording on both platforms, Logen
/// 2026-11-05). "This device" fits a phone and a Mac alike.
/// `MediaDeleteWordingTests` fails when the two apps drift apart.
enum MediaDeleteWording {
    static let mirrors = "Removes this file from your media servers. This device and your home vault keep their copies."
    static let everywhere = "Permanently removes this file from this device, your home vault and your media servers. This cannot be undone."
}
