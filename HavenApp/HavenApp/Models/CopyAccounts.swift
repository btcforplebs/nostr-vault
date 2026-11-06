import Foundation

/// The vault's accounts in a copy (docs/MESH_COPY_V2_CONTRACT.md §3.4,
/// `accounts-refuse-cases.json`, `accounts-merge-cases.json`): npubs and
/// names only, never a key. The app keeps `copy-accounts.json` in the relay
/// root current with its own accounts and their names; after a copy or a
/// catch-up the engine merges the other device's accounts into it, and the
/// app asks which of those to add here (look-only). Pure Foundation so
/// MediaLogicTests reads the fixtures.
enum CopyAccounts {
    static let fileName = "copy-accounts.json"
    static let maxAccounts = 64
    static let nameMax = 80
    static let maxSize = 64 << 10

    struct Account: Equatable, Hashable, Identifiable {
        var npub: String
        var name: String = ""
        var id: String { npub }
    }

    enum Refusal: String, Error {
        case badVersion = "bad_version"
        case secretValue = "secret_value"
        case unknownKey = "unknown_key"
        case badNpub = "bad_npub"
        case badName = "bad_name"
        case tooMany = "too_many"
    }

    // MARK: The refuse check (the engine's copyAccountsRefusal)

    /// The file's accounts, or why it may not be written, read or handed to
    /// AddAccountsC. Same order as the engine: size, JSON, secrets anywhere,
    /// fields and types, version, count, npubs, names.
    static func check(_ data: Data) -> Result<[Account], Refusal> {
        guard data.count <= maxSize else { return .failure(.tooMany) }
        guard let whole = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failure(.badVersion)
        }
        if secretAnywhere(whole) { return .failure(.secretValue) }
        guard let o = whole as? [String: Any],
              Set(o.keys).isSubset(of: ["v", "updated_at", "accounts"]) else { return .failure(.unknownKey) }
        guard let v = intField(o["v"]), intField(o["updated_at"]) != nil else { return .failure(.unknownKey) }
        var accounts: [Account] = []
        if let raw = o["accounts"], !(raw is NSNull) {
            guard let list = raw as? [Any] else { return .failure(.unknownKey) }
            for item in list {
                guard let a = item as? [String: Any], Set(a.keys).isSubset(of: ["npub", "name"]),
                      let npub = stringField(a["npub"]), let name = stringField(a["name"]) else {
                    return .failure(.unknownKey)
                }
                accounts.append(Account(npub: npub, name: name))
            }
        }
        guard v == 1 else { return .failure(.badVersion) }
        guard (1...maxAccounts).contains(accounts.count) else { return .failure(.tooMany) }
        for a in accounts {
            guard MeshPairing.npubHex(a.npub) != nil else { return .failure(.badNpub) }
            guard a.name.unicodeScalars.count <= nameMax else { return .failure(.badName) }
        }
        return .success(accounts)
    }

    /// `{"v":1,"updated_at":…,"accounts":[…]}`, only when it passes `check`.
    static func fileData(_ accounts: [Account], updatedAt: Int64) -> Data? {
        let list: [[String: Any]] = accounts.map { a in
            a.name.isEmpty ? ["npub": a.npub] : ["npub": a.npub, "name": a.name]
        }
        let object: [String: Any] = ["v": 1, "updated_at": updatedAt, "accounts": list]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              case .success = check(data) else { return nil }
        return data
    }

    // MARK: Merging (the engine's mergeCopyAccounts)

    /// Mine, then theirs that are new, in order. A name I have stays; a
    /// missing one is filled. Nothing is ever removed.
    static func merge(mine: [Account], theirs: [Account]) -> [Account] {
        var out = mine
        var at: [String: Int] = [:]
        for (i, a) in out.enumerated() { at[a.npub] = i }
        for a in theirs {
            if let i = at[a.npub] {
                if out[i].name.isEmpty { out[i].name = a.name }
                continue
            }
            at[a.npub] = out.count
            out.append(a)
        }
        return out
    }

    /// Whether `theirs` (npubs) holds one of `mine` (hex keys).
    static func shares(mine: Set<String>, theirs: [String]) -> Bool {
        theirs.contains { MeshPairing.npubHex($0).map(mine.contains) ?? false }
    }

    // MARK: This app's side

    /// The file this app writes: its own accounts (owner first) with the
    /// names it knows now, then every other account already in the file
    /// (what a copy or catch-up brought). Own names win here, as this device
    /// knows its own accounts best; nothing already in the file is dropped.
    static func ownFile(own: [Account], existing: [Account]) -> [Account] {
        var mine = own
        for i in mine.indices where mine[i].name.isEmpty {
            mine[i].name = existing.first(where: { $0.npub == mine[i].npub })?.name ?? ""
        }
        return Array(merge(mine: mine, theirs: existing).prefix(maxAccounts))
    }

    /// The accounts to ask about: in the file, not this device's own, and
    /// not settled (asked already, or own here once and since removed).
    static func offered(file: [Account], ownHex: Set<String>, settledHex: Set<String>) -> [Account] {
        var seen = Set<String>()
        return file.filter { a in
            guard let hex = MeshPairing.npubHex(a.npub), !ownHex.contains(hex), !settledHex.contains(hex) else {
                return false
            }
            return seen.insert(hex).inserted
        }
    }

    /// The JSON for AddAccountsC: the ticked accounts in the file's shape.
    static func addJSON(_ ticked: [Account], updatedAt: Int64) -> String? {
        guard !ticked.isEmpty, let data = fileData(ticked, updatedAt: updatedAt) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Helpers

    private static func secretAnywhere(_ v: Any) -> Bool {
        switch v {
        case let s as String: return CopySettings.secretString(s)
        case let a as [Any]: return a.contains(where: secretAnywhere)
        case let o as [String: Any]: return o.contains { CopySettings.secretString($0.key) || secretAnywhere($0.value) }
        default: return false
        }
    }

    /// An integer JSON number (not a bool, not a fraction), as Go's int64.
    private static func intField(_ v: Any?) -> Int64? {
        guard let v, !(v is NSNull) else { return 0 }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.rounded() == d, abs(d) < 9.2e18 else { return nil }
        return n.int64Value
    }

    /// A string, or absent / null (Go leaves the field empty).
    private static func stringField(_ v: Any?) -> String? {
        guard let v, !(v is NSNull) else { return "" }
        return v as? String
    }
}
