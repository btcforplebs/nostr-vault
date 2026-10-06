import Foundation

// MARK: - Share Inbox
//
// Hand-off folder between the share extension and the app. The extension only
// drops files here; the app's Media tab uploads them the same way it uploads a
// file picked with + → Files, so signing, the device relay and the outside
// Blossom servers stay in one place.
//
// Why a file in an App Group and not the shared keychain group the widgets
// use: a shared video is hundreds of megabytes, and a keychain item is not a
// filesystem. Why not the clipboard: a big video on the pasteboard is copied
// through memory twice and is readable by every other app.

enum NVShareInbox {
    static let appGroup = "group.com.havenapp.relay"
    private static let folderName = "ShareInbox"

    /// The inbox folder, created on first use. Nil when the process does not
    /// carry the App Group entitlement (the macOS app, or a mis-signed build).
    static var folder: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        let url = container.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Files waiting to be uploaded, oldest first. Partial writes are excluded.
    static func pending() -> [URL] {
        guard let folder,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls
            .filter { !$0.lastPathComponent.hasPrefix(partialPrefix) }
            .sorted { creationDate($0) < creationDate($1) }
    }

    static var hasPending: Bool { !pending().isEmpty }

    /// Moves a file the extension has finished copying into the inbox. The
    /// copy is written under a partial name first and renamed, so the app
    /// never picks up a half-written video.
    @discardableResult
    static func add(fileAt source: URL, preferredName: String) throws -> URL {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        let ext = (preferredName as NSString).pathExtension
        let base = ((preferredName as NSString).deletingPathExtension)
            .replacingOccurrences(of: "/", with: "-")
        let stem = "\(base.isEmpty ? "shared" : base)-\(UUID().uuidString.prefix(8))"
        let name = ext.isEmpty ? stem : "\(stem).\(ext)"
        let partial = folder.appendingPathComponent(partialPrefix + name)
        let final = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: partial)
        try FileManager.default.moveItem(at: partial, to: final)
        return final
    }

    /// Takes every pending file out of the inbox and into `destination`, so a
    /// second caller (the scene activating while a notification tap is being
    /// handled) finds nothing and cannot upload the same file twice.
    static func claimAll(into destination: URL) -> [URL] {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var claimed: [URL] = []
        for url in pending() {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            if (try? FileManager.default.moveItem(at: url, to: target)) != nil {
                claimed.append(target)
            }
        }
        return claimed
    }

    /// Identifier of the "ready to upload" notification, so a second share
    /// replaces the first banner instead of stacking another one.
    static let notificationID = "nv.share.inbox"

    private static let partialPrefix = ".partial-"

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
