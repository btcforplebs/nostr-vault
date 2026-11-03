import Foundation

// MARK: - Share queue
//
// Hand-off folder between the share extension and the app for share intents
// (NVShareIntent). Same trick as NVShareInbox: files are copied first, the
// JSON is written under a partial name and renamed last, so the app never
// reads half an intent. Claiming moves the JSON out of the shared folder, so
// two activations (a notification tap and the scene coming forward) cannot
// act on one share twice.
//
// Layout (docs/SHARE_PORTAL_CONTRACT.md §2):
//   <root>/<id>.json            the intent
//   <root>/files/<id>/<name>    its files
//   <root>/.partial-<id>.json   being written

struct NVShareQueue {
    static let appGroup = "group.com.havenapp.relay"
    static let folderName = "ShareQueue"
    /// The extension's "finish in Nostr Vault" notification. A second share
    /// replaces the banner instead of stacking another.
    static let notificationID = "nv.share.portal"

    let root: URL

    /// The App Group queue. Nil when the process has no App Group (the Mac
    /// app, or a mis-signed build).
    static var shared: NVShareQueue? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        return NVShareQueue(root: container.appendingPathComponent(folderName, isDirectory: true))
    }

    private static let partialPrefix = ".partial-"
    private var fm: FileManager { .default }

    func filesFolder(for id: String) -> URL {
        root.appendingPathComponent("files", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    // MARK: Write (extension)

    /// A file to copy in with an intent. The source is copied, never read
    /// into memory: the extension has a hard memory ceiling.
    struct Attachment {
        let source: URL
        let name: String
        let mime: String
    }

    /// Copies `attachments` in, then commits the intent. Returns the intent
    /// as written (its `files` filled in).
    @discardableResult
    func add(_ intent: NVShareIntent, attachments: [Attachment] = []) throws -> NVShareIntent {
        guard NVShareLimits.isValidID(intent.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var written = intent
        written.files = []
        if !attachments.isEmpty {
            let folder = filesFolder(for: intent.id)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var used = Set<String>()
            for attachment in attachments.prefix(NVShareLimits.files) {
                let name = Self.uniqueName(Self.safeName(attachment.name), used: &used)
                let target = folder.appendingPathComponent(name)
                try fm.copyItem(at: attachment.source, to: target)
                let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                written.files.append(.init(name: name, mime: attachment.mime,
                                           path: NVShareIntent.filePath(id: intent.id, name: name), bytes: bytes))
            }
        }
        let partial = root.appendingPathComponent("\(Self.partialPrefix)\(intent.id).json")
        let final = root.appendingPathComponent("\(intent.id).json")
        try written.encoded().write(to: partial, options: .atomic)
        try fm.moveItem(at: partial, to: final)
        return written
    }

    // MARK: Read / claim (app)

    /// Committed intents waiting, by file name. Partial writes excluded.
    func pendingFiles() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(Self.partialPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var hasPending: Bool { !pendingFiles().isEmpty }

    /// Moves every pending intent into `claimed` (another NVShareQueue, the
    /// app's private one) and returns the ones this caller now owns. The JSON
    /// moves first: whoever's move succeeds owns it. A JSON that does not
    /// decode is deleted with its files and never returned.
    func claimAll(into claimed: NVShareQueue) -> [NVShareIntent] {
        try? fm.createDirectory(at: claimed.root, withIntermediateDirectories: true)
        var out: [NVShareIntent] = []
        for url in pendingFiles() {
            let id = url.deletingPathExtension().lastPathComponent
            let target = claimed.root.appendingPathComponent(url.lastPathComponent)
            guard NVShareLimits.isValidID(id) else { try? fm.removeItem(at: url); continue }
            guard (try? fm.moveItem(at: url, to: target)) != nil else { continue }
            guard let data = try? Data(contentsOf: target), let intent = NVShareIntent.decode(data),
                  intent.id == id else {
                try? fm.removeItem(at: target)
                try? fm.removeItem(at: filesFolder(for: id))
                continue
            }
            let files = filesFolder(for: id)
            if fm.fileExists(atPath: files.path) {
                let dest = claimed.filesFolder(for: id)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try? fm.moveItem(at: files, to: dest)
            }
            out.append(intent)
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    /// Everything this queue holds that decodes, oldest first. For the app's
    /// claimed queue: what still waits for a review.
    func all() -> [NVShareIntent] {
        pendingFiles().compactMap { url in
            guard let data = try? Data(contentsOf: url), let intent = NVShareIntent.decode(data),
                  intent.id == url.deletingPathExtension().lastPathComponent else { return nil }
            return intent
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The local copy of one of an intent's files, or nil if it is missing.
    func fileURL(for file: NVShareIntent.File, of intent: NVShareIntent) -> URL? {
        guard NVShareLimits.isValidFileName(file.name),
              file.path == NVShareIntent.filePath(id: intent.id, name: file.name) else { return nil }
        let url = filesFolder(for: intent.id).appendingPathComponent(file.name)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    /// Done or dismissed: the intent and its files go.
    func remove(id: String) {
        guard NVShareLimits.isValidID(id) else { return }
        try? fm.removeItem(at: root.appendingPathComponent("\(id).json"))
        try? fm.removeItem(at: filesFolder(for: id))
    }

    // MARK: Names

    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = NVShareLimits.cap(cleaned, 120) ?? ""
        return cleaned.isEmpty ? "shared" : cleaned
    }

    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var candidate = name
        var n = 2
        while used.contains(candidate) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }
}
