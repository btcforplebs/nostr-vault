import Foundation

/// Merging this device's entries into a list published by any client. NIP-51
/// lists are replaceable, so publishing only what this device holds deletes
/// everything another client added. Twin of `ListMerge` in Android's
/// `NostrServiceListPublishing.kt`.
enum ListMerge {
    static let basesFileName = "list_publish_bases.json"

    /// Compares entries regardless of case, padding and a trailing slash.
    static func key(_ value: String) -> String {
        var out = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasSuffix("/") { out.removeLast() }
        return out.lowercased()
    }

    /// `local` as `[name, value]` tags, then the `published` tags kept: every
    /// tag of another name, and a `name` tag that is not local when
    /// `keepPublished` says so.
    static func tags(name: String, local: [String], published: [[String]],
                     keepPublished: (String) -> Bool) -> [[String]] {
        var seen = Set<String>()
        let mine = local
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(key($0)).inserted }
            .map { [name, $0] }
        let kept = published.filter { tag in
            guard let first = tag.first else { return false }
            if first != name { return true }
            return tag.count >= 2 && keepPublished(tag[1]) && seen.insert(key(tag[1])).inserted
        }
        return mine + kept
    }

    /// What this device last published per list, so the next publish can tell
    /// an entry another client added from one removed here. A list with no
    /// base yet (the first publish after this shipped) keeps every published
    /// entry: a removal made in that one publish stays on the published list,
    /// which only other clients read, rather than another client's entries
    /// being wiped.
    final class Bases {
        private let file: URL
        private static let lock = NSLock()

        init(file: URL) { self.file = file }

        /// The store in Application Support/Haven.
        static var shared: Bases {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Haven", isDirectory: true)
            return Bases(file: dir.appendingPathComponent(basesFileName))
        }

        func get(_ key: String) -> [String]? {
            Self.lock.lock(); defer { Self.lock.unlock() }
            return read()[key]
        }

        func put(_ key: String, _ entries: [String]) {
            Self.lock.lock(); defer { Self.lock.unlock() }
            var all = read()
            all[key] = entries
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(all).write(to: file, options: .atomic)
            } catch {
                #if DEBUG
                print("ListMerge: list base not saved: \(error)")
                #endif
            }
        }

        private func read() -> [String: [String]] {
            guard let data = try? Data(contentsOf: file),
                  let all = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
            return all
        }
    }
}
