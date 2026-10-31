import Foundation

/// The owner's media server list (BUD-03 kind 10063) set in another app,
/// brought into this device's upload servers. Uploads go to
/// `HavenConfig.activeBlossomMirrors`, so a server only on the published list
/// was never uploaded to. Twin of Android's `ServerListAdoption.kt`.
///
/// Adds only, and their order comes first: the published servers in the
/// owner's order, then this device's other servers. A server this device has
/// stays, and a server this device published and later removed is not added
/// back (it is in `base` but not in
/// `local`). Same newest-wins stamp as the DM inbox list: a list no newer
/// than the last change here, or than the last one adopted, changes nothing.
enum ServerListAdoption {

    struct Result: Equatable {
        let mirrors: [String]
        let added: [String]
        let updatedAt: Int64
    }

    /// Nil when nothing changes. `local` is `blossomMirrors`, `updatedAt` when
    /// it last changed, `published` the servers on the newest list and
    /// `publishedAt` its created_at, `base` what this device last published,
    /// `ownServers` the Mac relay's media address, which the app adds itself.
    static func adopt(
        local: [String],
        updatedAt: Int64?,
        published: [String],
        publishedAt: Int64,
        base: [String]?,
        ownServers: [String] = []
    ) -> Result? {
        if let updatedAt, publishedAt <= updatedAt { return nil }
        // A server this device has keeps its spelling here, so a later add
        // of the same address is still seen as a duplicate.
        var localByKey: [String: String] = [:]
        for url in local where localByKey[ListMerge.key(url)] == nil { localByKey[ListMerge.key(url)] = url }
        // Removed here after this device published it: not brought back.
        let removedHere = Set((base ?? []).map(ListMerge.key)).subtracting(localByKey.keys)
        var seen = removedHere.union(ownServers.map(ListMerge.key))
        // Their list first, in their order (Logen, 2026-10-31); this
        // device's other servers after it, in the order they were.
        let theirs = published
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { usable($0) && seen.insert(ListMerge.key($0)).inserted }
        let rest = local.filter { seen.insert(ListMerge.key($0)).inserted }
        let added = theirs.filter { localByKey[ListMerge.key($0)] == nil }
        let mirrors = theirs.map { localByKey[ListMerge.key($0)] ?? $0 } + rest
        return Result(mirrors: mirrors, added: added, updatedAt: publishedAt)
    }

    private static func usable(_ url: String) -> Bool {
        let lowered = url.lowercased()
        guard lowered.hasPrefix("https://") || lowered.hasPrefix("http://"), !url.contains(" ") else { return false }
        guard let host = URL(string: url)?.host?.lowercased(), !host.isEmpty else { return false }
        return !["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    }

    /// "Uploads to blossom.primal.net and 2 more", from the server URLs.
    static func summary(_ servers: [String]) -> String {
        guard let firstURL = servers.first else { return "No media server set" }
        let first = URL(string: firstURL.trimmingCharacters(in: .whitespaces))?.host ?? firstURL
        let more = servers.count - 1
        return more == 0 ? "Uploads to \(first)" : "Uploads to \(first) and \(more) more"
    }
}
