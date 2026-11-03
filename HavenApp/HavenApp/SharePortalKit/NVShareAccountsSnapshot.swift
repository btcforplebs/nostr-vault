import Foundation

// MARK: - Accounts snapshot
//
// The "post as" list the share extension shows. Written by the app into the
// App Group, read by the extension. npub, name and picture URL only: the
// extension never learns which signer an account uses, let alone a key.

struct NVShareAccountsSnapshot: Codable, Equatable, Sendable {
    struct Account: Codable, Equatable, Sendable {
        var npub: String
        var name: String
        var picture: String?
    }

    var v: Int = 1
    var active: String
    var accounts: [Account]

    static let fileName = "accounts.json"
    static let folderName = "SharePortal"

    static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(fileName)
    }

    static var sharedRoot: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: NVShareQueue.appGroup)
    }

    /// Nil when missing, unreadable or not version 1. Entries that are not an
    /// npub are dropped; names and pictures are capped.
    static func read(root: URL? = sharedRoot) -> NVShareAccountsSnapshot? {
        guard let root, let data = try? Data(contentsOf: fileURL(root: root)),
              var snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.v == 1 else { return nil }
        snapshot.accounts = snapshot.accounts.prefix(50).compactMap { a in
            guard a.npub.hasPrefix("npub1"), a.npub.count <= 100 else { return nil }
            return Account(npub: a.npub, name: NVShareLimits.cap(a.name, 100) ?? "",
                           picture: NVShareLimits.cap(a.picture, NVShareLimits.url))
        }
        return snapshot
    }

    func write(root: URL? = sharedRoot) {
        guard let root else { return }
        let url = Self.fileURL(root: root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        // Skip identical rewrites: scene activation fires often.
        if (try? Data(contentsOf: url)) == data { return }
        try? data.write(to: url, options: .atomic)
    }
}
