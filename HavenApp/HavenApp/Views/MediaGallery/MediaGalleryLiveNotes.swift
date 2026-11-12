import SwiftUI

/// Keeps the owner's `/files` room open while the Media tab is on screen and
/// redraws the tab when a note lands or goes (FileNotesLive). Its own
/// modifier: `MediaGalleryChangeHandlers` is at the size where the Swift
/// type-checker starts refusing the file.
struct MediaGalleryLiveNotes: ViewModifier {
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { FileNotesLive.shared.start() }
            .onDisappear { FileNotesLive.shared.stop() }
            .onReceive(FileNotesLive.shared.$tiles.dropFirst()) { _ in onChange() }
    }
}

extension FileNoteTile {
    /// The tile as a Media tab item, or nil with no address this tab can
    /// load (a vault-only note: the server check finds it once a server has it).
    func mediaItem(owner: String) -> MediaItem? {
        guard let first = urls.first, let url = URL(string: first) else { return nil }
        let type: MediaItem.MediaType
        let m = mime.lowercased()
        if m.hasPrefix("image/") { type = .image }
        else if m.hasPrefix("video/") { type = .video }
        else if m.hasPrefix("audio/") { type = .audio }
        else { type = .unknown }
        return MediaItem(id: Self.stableID(sha256), url: url, type: type,
                         dateAdded: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                         pubkey: owner, tags: nil, mimeType: mime)
    }

    /// The same id for the same hash on every redraw, so the grid keeps its cell.
    static func stableID(_ sha256: String) -> UUID {
        let hex = Array(sha256.prefix(32))
        guard hex.count == 32 else { return UUID() }
        let s = String(hex)
        let parts = [s.prefix(8), s.dropFirst(8).prefix(4), s.dropFirst(12).prefix(4), s.dropFirst(16).prefix(4), s.dropFirst(20)]
        return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
    }
}
