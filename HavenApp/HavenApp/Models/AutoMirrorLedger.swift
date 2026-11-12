import Foundation

/// What Auto-Mirror has already saved into this vault: each note media link
/// and the hash of the file it gave. Without it, every run downloaded again
/// every photo whose link is not named by its hash (the only links the
/// "already here" check could match) and signed for each one: about 1,100
/// bunker signatures in 25 minutes on an iPhone 18, nothing new saved.
/// Written after each save, so a run cut short resumes where it stopped.
/// Lives in the vault's data folder: starting the vault fresh forgets it too.
/// Android twin: none yet (Android Auto-Mirror reads hash-named links only).
struct AutoMirrorLedger: Codable, Equatable {
    static let fileName = "automirror_saved.json"

    /// Link -> hash of the file it gave (lowercase).
    private(set) var saved: [String: String] = [:]

    mutating func remember(url: URL, sha256: String) {
        saved[url.absoluteString] = sha256.lowercased()
    }

    /// The links still to download: not saved by an earlier run, and not a
    /// hash-named link whose file is already here. Saved once means skipped
    /// for good, so a photo deleted from the vault is not brought back.
    func toDownload(_ urls: [URL], localHashes: Set<String>) -> [URL] {
        urls.filter { url in
            if saved[url.absoluteString] != nil { return false }
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if name.count == 64, name.allSatisfy(\.isHexDigit), localHashes.contains(name) { return false }
            return true
        }
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
