import Foundation

/// What Auto-Mirror has already saved into this vault: each note media link
/// and the hash of the file it gave. Without it, every run downloaded again
/// every photo whose link is not named by its hash (the only links the
/// "already here" check could match) and signed for each one: about 1,100
/// bunker signatures in 25 minutes on an iPhone 18, nothing new saved.
/// Written after each save, so a run cut short resumes where it stopped.
/// Lives in the vault's data folder: starting the vault fresh forgets it too.
/// Android twin: `AutoMirrorState.kt` + `AutoMirrorRules.kt` (PR 1983).
/// The rules a run keeps are listed in docs/AUTO_MIRROR.md.
struct AutoMirrorLedger: Codable, Equatable {
    static let fileName = "automirror_saved.json"

    /// Link -> hash of the file it gave (lowercase).
    private(set) var saved: [String: String] = [:]

    mutating func remember(url: URL, sha256: String) {
        saved[url.absoluteString] = sha256.lowercased()
    }

    /// The links still to download: not saved by an earlier run, and not a
    /// link whose file is already here by its hash (named by it, or given by
    /// the note's `imeta` `x` in `knownHashes`). Two links known to give one
    /// file: only the first is downloaded. Saved once means skipped for good,
    /// so a photo deleted from the vault is not brought back.
    func toDownload(_ urls: [URL], localHashes: Set<String>, knownHashes: [String: String] = [:]) -> [URL] {
        var taken = Set<String>()
        return urls.filter { url in
            if saved[url.absoluteString] != nil { return false }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            let hash = knownHashes[url.absoluteString] ?? (Self.isHash(name) ? name : nil)
            guard let hash else { return true }
            if localHashes.contains(hash) { return false }
            return taken.insert(hash).inserted
        }
    }

    /// Link -> `x` from a note's `imeta` tags (NIP-92), lower-cased, hashes only.
    static func imetaHashes(_ tags: [[String]]) -> [String: String] {
        var out: [String: String] = [:]
        for tag in tags where tag.first == "imeta" {
            var url: String?
            var hash: String?
            for field in tag.dropFirst() {
                if field.hasPrefix("url ") { url = String(field.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
                if field.hasPrefix("x ") { hash = String(field.dropFirst(2)).trimmingCharacters(in: .whitespaces).lowercased() }
            }
            if let url, let hash, isHash(hash) { out[url] = hash }
        }
        return out
    }

    static func isHash(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func load(from dir: URL) -> AutoMirrorLedger {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)),
              let ledger = try? JSONDecoder().decode(AutoMirrorLedger.self, from: data) else { return AutoMirrorLedger() }
        return ledger
    }

    func save(to dir: URL) throws {
        try JSONEncoder().encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A downloaded file: saved into the vault, or already there.
enum AutoMirrorSave: Equatable {
    case store
    case alreadyHere

    static func decide(sha256: String, localHashes: Set<String>) -> AutoMirrorSave {
        localHashes.contains(sha256.lowercased()) ? .alreadyHere : .store
    }
}

/// How an Auto-Mirror run gets its files into this vault.
/// `.none`: in-process (`ImportOwnerBlobC`), no signer asked — the owner's
/// files, or a keyless vault. `.batch`: another account signs one upload
/// authorisation per batch (an `x` tag per hash, BUD-11), not one per photo,
/// so the files are filed under the key that saved them (`OwnVaultUpload`).
enum AutoMirrorSigning: Equatable {
    case none
    case batch

    /// Hashes per signature: keeps the signed event small enough for a
    /// NIP-46 bunker's relay (about 70 bytes per `x` tag).
    static let maxHashesPerSignature = 200

    static func plan(keyless: Bool, activeIsOwner: Bool) -> AutoMirrorSigning {
        keyless || activeIsOwner ? .none : .batch
    }

    static func batches<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: maxHashesPerSignature).map {
            Array(items[$0..<min($0 + maxHashesPerSignature, items.count)])
        }
    }
}

/// Rule 4: at most `maxDownloads` downloads per run, shared by the server
/// list half and the note links half. What is held back comes next run:
/// the ledger and the vault's hashes skip what this run saved.
struct AutoMirrorRunLimit: Equatable {
    static let maxDownloads = 200
    static let unlimited = AutoMirrorRunLimit(left: .max)

    private(set) var left: Int
    /// How many were held back for the next run.
    private(set) var held = 0

    init(left: Int = maxDownloads) { self.left = left }

    mutating func take<T>(_ items: [T]) -> [T] {
        let n = min(left, items.count)
        left -= n
        held += items.count - n
        return Array(items.prefix(n))
    }
}
