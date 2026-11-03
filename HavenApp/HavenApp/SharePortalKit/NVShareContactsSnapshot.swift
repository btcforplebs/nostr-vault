import Foundation

// MARK: - Recent private recipients
//
// "Send privately" in the share sheet offers the people this account last
// sent something to *from the share sheet*. Written by the app after a send
// (DMShareHandler), read by the extension. npub, name and picture URL only:
// no messages, no follows, no whole contact list. At most `maxPerAccount` per
// account, newest first. Android twin: ShareContactsSnapshot.kt.

struct NVShareContactsSnapshot: Codable, Equatable, Sendable {
    struct Contact: Codable, Equatable, Sendable {
        var npub: String
        var name: String
        var picture: String?
    }

    var v: Int = 1
    /// Account npub → its recent recipients, newest first.
    var recent: [String: [Contact]] = [:]

    static let fileName = "contacts.json"
    static let maxPerAccount = 8
    static let maxAccounts = 50

    static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(NVShareAccountsSnapshot.folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func contacts(for account: String?) -> [Contact] {
        guard let account else { return [] }
        return recent[account] ?? []
    }

    /// `contact` moved to the front of `account`'s list, once, list capped.
    func recording(_ contact: Contact, for account: String) -> NVShareContactsSnapshot {
        guard Self.isNpub(account), Self.isNpub(contact.npub) else { return self }
        var copy = self
        var list = (recent[account] ?? []).filter { $0.npub != contact.npub }
        list.insert(Self.capped(contact), at: 0)
        copy.recent[account] = Array(list.prefix(Self.maxPerAccount))
        return copy
    }

    /// Drops every account not in `keep` (accounts removed from the device).
    func keeping(accounts keep: Set<String>) -> NVShareContactsSnapshot {
        var copy = self
        copy.recent = recent.filter { keep.contains($0.key) }
        return copy
    }

    /// Nil when missing, unreadable or not version 1. Anything that is not an
    /// npub is dropped; names and pictures are capped.
    static func decode(_ data: Data) -> NVShareContactsSnapshot? {
        guard var s = try? JSONDecoder().decode(Self.self, from: data), s.v == 1 else { return nil }
        var clean: [String: [Contact]] = [:]
        for (account, list) in s.recent where isNpub(account) {
            guard clean.count < maxAccounts else { break }
            clean[account] = Array(list.filter { isNpub($0.npub) }.prefix(maxPerAccount).map(capped))
        }
        s.recent = clean
        return s
    }

    static func read(root: URL? = NVShareAccountsSnapshot.sharedRoot) -> NVShareContactsSnapshot? {
        guard let root, let data = try? Data(contentsOf: fileURL(root: root)) else { return nil }
        return decode(data)
    }

    func write(root: URL? = NVShareAccountsSnapshot.sharedRoot) {
        guard let root else { return }
        let url = Self.fileURL(root: root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func isNpub(_ s: String) -> Bool {
        s.hasPrefix("npub1") && s.count == 63
    }

    private static func capped(_ c: Contact) -> Contact {
        Contact(npub: c.npub, name: NVShareLimits.cap(c.name, 100) ?? "",
                picture: NVShareLimits.cap(c.picture, NVShareLimits.url))
    }
}
