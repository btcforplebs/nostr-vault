import Foundation

// MARK: - Share intent
//
// What the share extension leaves for the app: which action the person picked,
// what they shared, and the small form they filled in. No key, no NWC string,
// no signer: the app reads this, shows a review card and signs there.
//
// The JSON is the contract in docs/SHARE_PORTAL_CONTRACT.md, shared with
// Android (shareportal/ShareIntent.kt) and tested against the same fixtures.
// Every field came from another app, so decoding validates and caps instead
// of trusting: one bad field rejects the whole intent.

/// The 13 things a share can become. Raw values are the wire names.
enum NVShareAction: String, CaseIterable, Codable, Sendable {
    case highlight
    case bookmark
    case privateCopy = "private_copy"
    case articleClip = "article_clip"
    case mediaPost = "media_post"
    case upload
    case recipe
    case profile
    case pay
    case dm
    case status
    case calendar
    case label
}

struct NVShareIntent: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        var url: String?
        var title: String?
        var text: String?
        var selection: String?
        var app: String?
        var ldTypes: [String] = []
    }

    struct File: Equatable, Sendable {
        var name: String
        var mime: String
        /// `files/<id>/<name>`, relative to the queue folder.
        var path: String
        var bytes: Int
    }

    static let version = 1

    var id: String
    var createdAt: Int
    /// The account to act as (`npub1…`); nil means the one active when the
    /// app claims it.
    var account: String?
    var action: NVShareAction
    var source = Source()
    var files: [File] = []
    var form: [String: String] = [:]

    init(id: String = UUID().uuidString, createdAt: Int = Int(Date().timeIntervalSince1970),
         account: String? = nil, action: NVShareAction, source: Source = Source(),
         files: [File] = [], form: [String: String] = [:]) {
        self.id = id
        self.createdAt = createdAt
        self.account = account
        self.action = action
        self.source = source.capped()
        self.files = files
        self.form = form
    }

    /// Older than this, the review card says so before anything is signed.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince1970 - TimeInterval(createdAt) > Self.staleAfter
    }
}

// MARK: - Limits

enum NVShareLimits {
    static let url = 4_096
    static let title = 1_000
    static let text = 100_000
    static let selection = 10_000
    static let app = 200
    static let ldTypes = 20
    static let ldType = 100
    static let files = 20
    static let formKeys = 32
    static let formKey = 64
    static let formValue = 20_000
    static let idLength = 64

    /// Cuts to `max` UTF-16 units (the unit Kotlin's `String.length` counts),
    /// backing off one if the cut would split a surrogate pair.
    static func cap(_ s: String?, _ max: Int) -> String? {
        guard let s else { return nil }
        let units = Array(s.utf16)
        guard units.count > max else { return s }
        var end = max
        if end > 0, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[0..<end], as: UTF16.self)
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= idLength
            && id.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A file name the queue may create: one path component, not hidden.
    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= 255 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

extension NVShareIntent.Source {
    func capped() -> Self {
        var s = self
        s.url = NVShareLimits.cap(url, NVShareLimits.url)
        s.title = NVShareLimits.cap(title, NVShareLimits.title)
        s.text = NVShareLimits.cap(text, NVShareLimits.text)
        s.selection = NVShareLimits.cap(selection, NVShareLimits.selection)
        s.app = NVShareLimits.cap(app, NVShareLimits.app)
        s.ldTypes = Array(ldTypes.prefix(NVShareLimits.ldTypes)).compactMap { NVShareLimits.cap($0, NVShareLimits.ldType) }
        return s
    }
}

// MARK: - JSON

extension NVShareIntent {
    /// Decodes and validates. Nil for anything that breaks the contract.
    static func decode(_ data: Data) -> NVShareIntent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return decode(object: object)
    }

    static func decode(object: Any) -> NVShareIntent? {
        guard let dict = object as? [String: Any],
              intValue(dict["v"]) == version,
              let id = dict["id"] as? String, NVShareLimits.isValidID(id),
              let createdAt = intValue(dict["created_at"]),
              let rawAction = dict["action"] as? String,
              let action = NVShareAction(rawValue: rawAction) else { return nil }

        var account: String?
        if let value = dict["account"], !(value is NSNull) {
            guard let npub = value as? String else { return nil }
            let trimmed = npub.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || (trimmed.hasPrefix("npub1") && trimmed.utf16.count <= 100) else { return nil }
            account = trimmed.isEmpty ? nil : trimmed
        }

        var source = Source()
        if let value = dict["source"], !(value is NSNull) {
            guard let s = value as? [String: Any] else { return nil }
            func str(_ key: String) -> String?? {
                guard let v = s[key], !(v is NSNull) else { return .some(nil) }
                guard let string = v as? String else { return nil }
                return .some(string)
            }
            guard let url = str("url"), let title = str("title"), let text = str("text"),
                  let selection = str("selection"), let app = str("app") else { return nil }
            source = Source(url: url, title: title, text: text, selection: selection, app: app)
            if let types = s["ld_types"], !(types is NSNull) {
                guard let list = types as? [Any] else { return nil }
                let strings = list.compactMap { $0 as? String }
                guard strings.count == list.count else { return nil }
                source.ldTypes = strings
            }
        }

        var files: [File] = []
        if let value = dict["files"], !(value is NSNull) {
            guard let list = value as? [Any], list.count <= NVShareLimits.files else { return nil }
            for entry in list {
                guard let f = entry as? [String: Any],
                      let name = f["name"] as? String, NVShareLimits.isValidFileName(name),
                      let mime = f["mime"] as? String, mime.utf16.count <= 255,
                      let path = f["path"] as? String, path == filePath(id: id, name: name),
                      let bytes = intValue(f["bytes"]), bytes >= 0 else { return nil }
                files.append(File(name: name, mime: mime, path: path, bytes: bytes))
            }
        }

        var form: [String: String] = [:]
        if let value = dict["form"], !(value is NSNull) {
            guard let f = value as? [String: Any], f.count <= NVShareLimits.formKeys else { return nil }
            for (key, v) in f {
                guard !key.isEmpty, key.utf16.count <= NVShareLimits.formKey, let string = v as? String else { return nil }
                form[key] = NVShareLimits.cap(string, NVShareLimits.formValue)
            }
        }

        return NVShareIntent(id: id, createdAt: createdAt, account: account, action: action,
                             source: source, files: files, form: form)
    }

    func encoded() -> Data {
        var src: [String: Any] = [:]
        if let v = source.url { src["url"] = v }
        if let v = source.title { src["title"] = v }
        if let v = source.text { src["text"] = v }
        if let v = source.selection { src["selection"] = v }
        if let v = source.app { src["app"] = v }
        if !source.ldTypes.isEmpty { src["ld_types"] = source.ldTypes }
        var dict: [String: Any] = [
            "v": Self.version, "id": id, "created_at": createdAt, "action": action.rawValue,
            "source": src, "form": form,
            "files": files.map { ["name": $0.name, "mime": $0.mime, "path": $0.path, "bytes": $0.bytes] as [String: Any] },
        ]
        if let account { dict["account"] = account }
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    static func filePath(id: String, name: String) -> String { "files/\(id)/\(name)" }

    /// JSON integers only: a string or a fraction is not a version or a time.
    private static func intValue(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 9e15 else { return nil }
        return n.intValue
    }
}
