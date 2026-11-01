import SwiftUI
import UniformTypeIdentifiers

/// Where one attachment's upload has got to. It starts the moment the
/// attachment is picked, not on Post.
enum ComposerUploadState: Equatable {
    /// Picked; waiting behind the uploads ahead of it (they run one at a time).
    case waiting
    /// Going up. `progress` runs from 0 to 1.
    case uploading(progress: Double)
    /// On an outside server (or picked from the relay): `url` is set.
    case hosted
    /// In this device's relay only; no outside server answered. The post
    /// waits in `MediaPostQueue` unless one answers by Post.
    case savedOnDevice
    /// Did not upload. `message` says why; Post tries once more.
    case failed(message: String)

    var isFinished: Bool {
        switch self {
        case .hosted, .savedOnDevice, .failed: return true
        case .waiting, .uploading: return false
        }
    }
}

/// The note being written: its text, its photos and where each photo's
/// upload is. One model, so the editor, the photo strip, the preview and Post
/// all read the same thing.
@MainActor
final class ComposerNote: ObservableObject {
    /// Every change, the author's or the app's, moves the photo anchors.
    @Published var text: String = "" {
        didSet { shiftAnchors(from: oldValue, to: text) }
    }
    @Published var attachments: [ComposeView.Attachment] = []
    /// The caret (or selection) in the editor, in UTF-16 units.
    @Published var selection = NSRange(location: 0, length: 0)

    /// Where each attachment still waiting for its link sits in `text`. An
    /// entry goes once the link is written in.
    var anchors: [UUID: Int] = [:]
    /// Set just before the app changes `text` itself, so the @mention and
    /// :emoji pickers don't read a written-in link as typing.
    var appEdited = false
    /// Each attachment's upload, for cancelling and for Post to wait on.
    var uploads: [UUID: Task<Void, Never>] = [:]
    /// The last upload queued; the next one waits for it.
    var lastUpload: Task<Void, Never>?
    /// Once one attachment found every outside server down, the rest save on
    /// this device only rather than each waiting out the same retry.
    var skipOutsideServers = false
    /// The outside servers that did not answer, for the queued-post message.
    var unreachableServers: [String] = []

    private func shiftAnchors(from old: String, to new: String) {
        guard old != new, !anchors.isEmpty else { return }
        for (id, anchor) in anchors {
            anchors[id] = ComposerPlacement.shiftAnchor(anchor, old: old, new: new)
        }
    }

    /// Writes `link` in at the attachment's anchor (the end if it has none).
    func place(_ link: String, for id: UUID) {
        let anchor = anchors.removeValue(forKey: id) ?? text.utf16.count
        guard !text.contains(link) else { return }
        let out = ComposerPlacement.insert(link, at: anchor, in: text)
        appEdited = true
        text = out.text
        // Photos picked together share one anchor: each next one goes after
        // this link, so they read in the order they were picked.
        for (other, a) in anchors where a == anchor { anchors[other] = out.end }
    }

    /// Moves a hosted attachment's link to the caret.
    func moveToCaret(_ id: UUID) {
        guard let link = attachments.first(where: { $0.id == id })?.url?.absoluteString else { return }
        var caret = min(selection.location + selection.length, text.utf16.count)
        if text.contains(link) {
            let old = text
            let without = ComposerPlacement.remove(link, from: old)
            caret = ComposerPlacement.shiftAnchor(caret, old: old, new: without)
            appEdited = true
            text = without
        }
        anchors[id] = caret
        place(link, for: id)
    }

    /// Takes an attachment out: stops its upload and removes its link.
    func remove(_ id: UUID) {
        uploads.removeValue(forKey: id)?.cancel()
        anchors.removeValue(forKey: id)
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments.remove(at: index)
        if let fileURL = attachment.fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        if let link = attachment.url?.absoluteString, text.contains(link) {
            appEdited = true
            text = ComposerPlacement.remove(link, from: text)
        }
    }

    func update(_ id: UUID, _ change: (inout ComposeView.Attachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        change(&attachments[index])
    }

    var unfinishedUploads: Int { attachments.filter { !$0.upload.isFinished }.count }

    /// How far the unfinished uploads have got, 0 to 1.
    var unfinishedProgress: Double {
        let open = attachments.filter { !$0.upload.isFinished }
        guard !open.isEmpty else { return 1 }
        let sum = open.reduce(0.0) { total, a in
            if case .uploading(let p) = a.upload { return total + p }
            return total
        }
        return sum / Double(open.count)
    }
}
