import Foundation

/// An unsent article, recipe or poll, as its composer left it. Notes have
/// their own drafts (`DraftService`, synced to the private relay); these stay
/// on this device only. Twin: Android `ComposerDraft` (not built yet).
struct ComposerDraft: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case article, recipe, poll

        /// Plural label for the drafts list, e.g. "Article drafts".
        var listTitle: String {
            switch self {
            case .article: return "Article drafts"
            case .recipe: return "Recipe drafts"
            case .poll: return "Poll drafts"
            }
        }
    }

    var id: String = UUID().uuidString
    var kind: Kind
    var updatedAt = Date()

    // Article and recipe
    var title = ""
    var summary = ""
    /// The article body, or a recipe's chef's notes.
    var body = ""
    /// True when a cover photo is saved beside the draft (see `ComposerDraftStore.cover`).
    var hasCover = false

    // Recipe
    var prepTime = ""
    var cookTime = ""
    var servings = ""
    var ingredients = ""
    var directions = ""
    var categories = ""

    // Poll
    var question = ""
    var options: [String] = []
    var multipleChoice = false
    /// `PollComposeView.Closing.rawValue`; kept as text so the model needs no view types.
    var closing: String?
    var customEnd: Date?

    init(kind: Kind) {
        self.kind = kind
        if kind == .poll { options = ["", ""] }
    }

    /// A form's content with no id or save time yet, so two snapshots of the
    /// same form compare equal (`ComposerDraftKeeper` stamps both on save).
    static func snapshot(_ kind: Kind) -> ComposerDraft {
        var d = ComposerDraft(kind: kind)
        d.id = ""
        d.updatedAt = .distantPast
        return d
    }

    /// Whether there is anything worth keeping. A poll's closing choice alone,
    /// or a form the user opened and left, is not a draft.
    var hasContent: Bool {
        let texts: [String]
        switch kind {
        case .article:
            texts = [title, summary, body]
        case .recipe:
            texts = [title, summary, body, prepTime, cookTime, servings, ingredients, directions, categories]
        case .poll:
            texts = [question] + options
        }
        return hasCover || texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// One line for the drafts list.
    var previewTitle: String {
        let main = kind == .poll ? question : title
        let trimmed = main.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return kind == .poll ? "Untitled poll" : "Untitled"
    }

    /// Second line for the drafts list: the start of the body, or the options.
    var previewDetail: String {
        let text: String
        switch kind {
        case .article: text = body.isEmpty ? summary : body
        case .recipe: text = summary.isEmpty ? ingredients : summary
        case .poll:
            text = options.map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= 100 ? flat : String(flat.prefix(100)) + "…"
    }

    /// Same content, ignoring when it was saved; used to skip no-op saves.
    func sameContent(as other: ComposerDraft) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        return a == b
    }
}

/// Composer drafts on disk: one JSON file per account, and each draft's cover
/// photo as its own JPEG beside it so the list file stays small.
final class ComposerDraftStore {
    static let shared = ComposerDraftStore(
        directory: DeletedNotesStore.defaultDirectory().appendingPathComponent("ComposerDrafts", isDirectory: true))

    private let directory: URL
    private let lock = NSLock()
    private var loaded: [String: [ComposerDraft]] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The account's drafts of `kind`, newest first.
    func drafts(_ kind: ComposerDraft.Kind, account: String) -> [ComposerDraft] {
        lock.lock(); defer { lock.unlock() }
        return draftsLocked(account: account)
            .filter { $0.kind == kind }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func draft(id: String, account: String) -> ComposerDraft? {
        lock.lock(); defer { lock.unlock() }
        return draftsLocked(account: account).first { $0.id == id }
    }

    /// Adds or replaces the draft with `draft.id`, and writes or removes its
    /// cover. A draft with no content is deleted instead, so clearing every
    /// field of a saved draft does not leave an empty row in the list.
    func save(_ draft: ComposerDraft, cover: Data?, account: String) {
        guard draft.hasContent || cover != nil else {
            delete(id: draft.id, account: account)
            return
        }
        lock.lock(); defer { lock.unlock() }
        var stored = draft
        stored.hasCover = cover != nil
        var list = draftsLocked(account: account)
        if let index = list.firstIndex(where: { $0.id == stored.id }) {
            list[index] = stored
        } else {
            list.append(stored)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coverURL = coverURL(id: stored.id, account: account)
        if let cover {
            try? cover.write(to: coverURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: coverURL)
        }
        writeLocked(list, account: account)
    }

    func delete(id: String, account: String) {
        lock.lock(); defer { lock.unlock() }
        var list = draftsLocked(account: account)
        let before = list.count
        list.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: coverURL(id: id, account: account))
        guard list.count != before else { return }
        writeLocked(list, account: account)
    }

    func cover(for draft: ComposerDraft, account: String) -> Data? {
        guard draft.hasCover else { return nil }
        return try? Data(contentsOf: coverURL(id: draft.id, account: account))
    }

    func fileURL(forAccount account: String) -> URL {
        directory.appendingPathComponent("composer_drafts_\(Self.safeKey(account)).json")
    }

    private func coverURL(id: String, account: String) -> URL {
        let safeID = id.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("cover_\(Self.safeKey(account))_\(safeID).jpg")
    }

    private static func safeKey(_ account: String) -> String {
        account.isEmpty ? "owner" : account.replacingOccurrences(of: "/", with: "_")
    }

    private func draftsLocked(account: String) -> [ComposerDraft] {
        if let cached = loaded[account] { return cached }
        var list: [ComposerDraft] = []
        if let data = try? Data(contentsOf: fileURL(forAccount: account)),
           let decoded = try? JSONDecoder().decode([ComposerDraft].self, from: data) {
            list = decoded
        }
        loaded[account] = list
        return list
    }

    private func writeLocked(_ list: [ComposerDraft], account: String) {
        loaded[account] = list
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL(forAccount: account), options: .atomic)
        }
    }
}
