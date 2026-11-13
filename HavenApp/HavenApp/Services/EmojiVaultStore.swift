import Foundation
import CryptoKit

/// The Vault's Emoji page (RESEARCH/NV_CUSTOM_EMOJI_PLAN.md §4): saved copies
/// of the account's emoji sets' images. A copy is a vault blob plus a `/files`
/// emoji note (EmojiNote) signed by this device's mesh key, so copy v2 brings
/// it to every paired device and the other devices hear the note live.
///
/// - Save copies: fetch each set image not saved yet (a dead link is also
///   asked of other servers by its hash), store it, note it. Publishes
///   nothing public.
/// - Zip import: zip images matched to the sets' emoji (§4.1), saved the same way.
/// - Add / Remove a set: rewrites the account's 10030 (pick 5).
/// - The sets' 30030s, others' too, are sent again to the account's relays
///   and kept in the vault, so a set its author deletes is still readable.
///
/// Rules are `EmojiVaultLogic`. Android `service/EmojiVaultStore.kt`.
@MainActor
final class EmojiVaultStore: ObservableObject {
    static let shared = EmojiVaultStore()

    /// Every saved copy, by hash: what the room's emoji notes say, plus this
    /// device's saves the room hasn't echoed yet.
    @Published private(set) var copies: [String: EmojiCopy] = [:]
    /// Hashes some plain (non-emoji) note names: those stay in Media.
    @Published private(set) var plainHashes: Set<String> = []
    /// Links that failed, with every other server, on the last try.
    @Published private(set) var dead: Set<String> = []
    @Published private(set) var progress: Progress?
    /// What the last Save copies or zip import did.
    @Published private(set) var lastResult: String?
    /// Zip files that matched no set emoji, from the last import.
    @Published private(set) var unmatchedZipFiles: [String] = []
    /// Addresses being added or removed right now.
    @Published private(set) var listing: Set<String> = []

    struct Progress: Equatable {
        let title: String
        var done: Int
        let total: Int
    }

    /// Hashes kept out of Media: every live note for them is an emoji note.
    var hiddenFromMedia: Set<String> { Set(copies.keys).subtracting(plainHashes) }

    private var owner = ""
    /// This device's saves, kept until the room has a note for the hash.
    private var pending: [String: EmojiCopy] = [:]
    private var room: [String: EmojiCopy] = [:]
    private var work: Task<Void, Never>?

    // MARK: Index (persisted per account)

    private struct Saved: Codable {
        var room: [String: EmojiCopy] = [:]
        var pending: [String: EmojiCopy] = [:]
        var plain: Set<String> = []
        var dead: Set<String> = []
    }

    private func indexURL(_ owner: String) -> URL? {
        guard FileNote.isHex64(owner) else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("emoji-vault", isDirectory: true)
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir?.appendingPathComponent("\(owner).json")
    }

    /// Switches to the active account's index (another account's copies
    /// never show).
    func useActiveAccount() {
        let active = NostrService.shared.activeHexPubkey
        guard active != owner else { return }
        owner = active
        var saved = Saved()
        if let url = indexURL(active), let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Saved.self, from: data) { saved = decoded }
        room = saved.room
        pending = saved.pending
        plainHashes = saved.plain
        dead = saved.dead
        rebuild()
    }

    private func persist() {
        guard let url = indexURL(owner),
              let data = try? JSONEncoder().encode(Saved(room: room, pending: pending, plain: plainHashes, dead: dead)) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func rebuild() {
        var all = room
        for (sha, copy) in pending {
            if let have = all[sha] { all[sha]?.note = have.note.merged(with: copy.note) } else { all[sha] = copy }
        }
        if all != copies { copies = all }
        Self.publishURLIndex(owner: owner, copies: all)
    }

    /// The room's view (FileNotesLive), for the room's owner.
    func ingest(owner roomOwner: String, copies live: [String: EmojiCopy], plain: Set<String>) {
        useActiveAccount()
        guard roomOwner == owner else { return }
        room = live
        // A save stays pending until the room's notes name all it said.
        pending = pending.filter { sha, copy in
            guard let seen = live[sha] else { return true }
            return !copy.note.emoji.allSatisfy(seen.note.emoji.contains)
        }
        if plain != plainHashes { plainHashes = plain }
        rebuild()
        persist()
    }

    // MARK: Local file for a link (any thread)

    private nonisolated(unsafe) static var urlIndex: [String: String] = [:]
    private nonisolated(unsafe) static var hashes: Set<String> = []
    private nonisolated(unsafe) static var folder: URL?
    private static let indexLock = NSLock()

    private static func publishURLIndex(owner: String, copies: [String: EmojiCopy]) {
        let byURL = EmojiVaultLogic.copiesByURL(copies)
        indexLock.lock()
        urlIndex = byURL
        hashes = Set(copies.keys)
        folder = blossomDir()
        indexLock.unlock()
    }

    /// This device's Blossom folder, where a copy's file lives.
    static func blossomDir() -> URL {
        let config = ConfigService.shared
        return config.relayDataDir.appendingPathComponent(config.config.blossomPath)
    }

    static func blossom() -> BlossomService {
        BlossomService(configService: ConfigService.shared, nostrService: NostrService.shared)
    }

    /// The vault file for an emoji link when a copy is on this device: by
    /// the copy's notes, or by the hash the link carries.
    nonisolated static func localFile(forURL url: String) -> URL? {
        indexLock.lock()
        let sha = urlIndex[url] ?? EmojiVaultLogic.hashInURL(url).flatMap { hashes.contains($0) ? $0 : nil }
        indexLock.unlock()
        guard let sha else { return nil }
        indexLock.lock()
        let dir = folder
        indexLock.unlock()
        return dir.flatMap { CopiedInDate.storedFile(sha256: sha, in: $0) }
    }

    // MARK: Save copies

    var isWorking: Bool { work != nil }

    func saveCopies(sets: [EmojiLibrary.EmojiSet]) {
        guard work == nil else { return }
        useActiveAccount()
        let jobs = Array(EmojiVaultLogic.jobs(sets: sets, copies: copies))
        let ownServers = ConfigService.shared.config.activeBlossomMirrors
        let account = owner
        lastResult = nil
        progress = Progress(title: "Saving copies", done: 0, total: jobs.count)
        work = Task { [weak self] in
            var tally = EmojiVaultLogic.Tally()
            var totalBytes: Int64 = 0
            for (index, job) in jobs.enumerated() {
                guard let self, !Task.isCancelled, NostrService.shared.activeHexPubkey == account else { break }
                defer { self.progress?.done = index + 1 }
                if index >= EmojiVaultLogic.maxFiles || totalBytes >= EmojiVaultLogic.maxTotalBytes {
                    tally.overCap += 1
                    continue
                }
                switch await Self.fetch(job.url, ownServers: ownServers) {
                case .image(let data, let mime):
                    totalBytes += Int64(data.count)
                    switch await self.keep(data: data, mime: mime, emoji: job.emoji) {
                    case .saved: tally.saved += 1
                    case .already: tally.already += 1
                    case .failed: tally.dead += 1
                    }
                    self.dead.remove(job.url)
                case .tooBig: tally.tooBig += 1
                case .notImage: tally.notImage += 1
                case .dead:
                    tally.dead += 1
                    self.dead.insert(job.url)
                }
            }
            guard let self else { return }
            await self.resendSets(addresses: sets.map(\.address))
            self.persist()
            self.lastResult = tally.summary
            self.progress = nil
            self.work = nil
            Self.blossom().announceStoredInVault()
        }
    }

    func cancel() {
        work?.cancel()
    }

    enum Kept { case saved, already, failed }

    /// Stores `data` in this device's vault (once per hash) and notes it with
    /// `emoji`. A hash already noted for every one of `emoji` is left alone.
    private func keep(data: Data, mime: String, emoji: [CustomEmoji]) async -> Kept {
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let have = copies[sha]?.note.emoji ?? []
        let missing = emoji.filter { e in !have.contains { $0.shortcode == e.shortcode && $0.url == e.url } }
        guard !missing.isEmpty else { return .already }
        let blossom = Self.blossom()
        if CopiedInDate.storedFile(sha256: sha, in: Self.blossomDir()) == nil {
            let isOwner = NostrService.shared.activeHexPubkey == NostrService.shared.ownerHexPubkey
            // The owner's copy goes in-process: no upload signature per
            // image, so a bunker isn't asked thousands of times.
            let stored = isOwner
                ? await blossom.importToOwnVaultInProcess(source: .data(data), sha256: sha, contentType: mime)
                : await blossom.storeLocally(source: .data(data), sha256: sha, contentType: mime, mirrorToExternal: false) != nil
            guard stored else { return .failed }
        }
        // Every set emoji using this image, so the note names them all.
        let all = have.isEmpty ? emoji : missing
        FileNotesOutbox.uploaded(sha256: sha, mime: mime, size: data.count, servers: [],
                                 extraTags: EmojiNote.tags(for: all))
        let note = EmojiNote(emoji: all.map { CustomEmoji(shortcode: $0.shortcode, url: $0.url) },
                             sets: EmojiNote.read(EmojiNote.tags(for: all))?.sets ?? [])
        if var p = pending[sha] { p.note = p.note.merged(with: note); pending[sha] = p }
        else { pending[sha] = EmojiCopy(sha256: sha, mime: mime, size: Int64(data.count), note: note) }
        rebuild()
        return .saved
    }

    // MARK: Fetch (link, then other servers by hash)

    enum Fetched {
        case image(Data, mime: String)
        case tooBig, notImage, dead
    }

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// The image at `url`, or from another server holding the hash its link
    /// carries (checked against that hash).
    nonisolated static func fetch(_ url: String, ownServers: [String]) async -> Fetched {
        guard let link = URL(string: url) else { return .dead }
        switch await download(link) {
        case .image(let data, let mime): return .image(data, mime: mime)
        case .tooBig: return .tooBig
        case .notImage: return .notImage
        case .dead: break
        }
        guard let want = EmojiVaultLogic.hashInURL(url) else { return .dead }
        for other in EmojiVaultLogic.otherServerURLs(for: url, own: ownServers) {
            if case .image(let data, let mime) = await download(other),
               SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == want {
                return .image(data, mime: mime)
            }
        }
        return .dead
    }

    /// One GET, read up to the size cap, typed by its first bytes.
    nonisolated static func download(_ url: URL) async -> Fetched {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http",
              !(url.host?.lowercased().hasSuffix(".fips") ?? true) else { return .dead }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return .dead }
            if http.expectedContentLength > EmojiVaultLogic.maxImageBytes { return .tooBig }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if Int64(data.count) > EmojiVaultLogic.maxImageBytes { return .tooBig }
            }
            guard let mime = sniffImage(data) else { return data.isEmpty ? .dead : .notImage }
            return .image(data, mime: mime)
        } catch {
            return .dead
        }
    }

    /// png/jpeg/gif/webp/avif by their first bytes, else nil.
    nonisolated static func sniffImage(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(16))
        func at(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, Array("GIF8".utf8)) { return "image/gif" }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) { return "image/webp" }
        if at(4, Array("ftyp".utf8)) && (at(8, Array("avif".utf8)) || at(8, Array("avis".utf8))) { return "image/avif" }
        return nil
    }

    // MARK: Zip import

    func importZip(_ zip: URL, sets: [EmojiLibrary.EmojiSet]) {
        guard work == nil else { return }
        useActiveAccount()
        let account = owner
        lastResult = nil
        unmatchedZipFiles = []
        progress = Progress(title: "Reading the zip", done: 0, total: 1)
        work = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { Self.readZip(zip) }.value
            guard let self else { return }
            defer {
                if let dir = read.dir { try? FileManager.default.removeItem(at: dir) }
            }
            guard let files = read.files else {
                self.lastResult = read.error ?? "That zip couldn't be opened."
                self.progress = nil
                self.work = nil
                return
            }
            let result = EmojiVaultLogic.matchZip(files.map(\.file), sets: sets, copies: self.copies)
            let paths = Dictionary(files.map { ($0.file.name + "\u{0}" + $0.file.sha256, $0.path) }, uniquingKeysWith: { a, _ in a })
            var tally = EmojiVaultLogic.Tally()
            tally.tooBig = read.tooBig
            tally.notImage = read.notImage
            self.progress = Progress(title: "Saving from the zip", done: 0, total: result.matched.count)
            for (index, match) in result.matched.enumerated() {
                guard !Task.isCancelled, NostrService.shared.activeHexPubkey == account else { break }
                defer { self.progress?.done = index + 1 }
                guard let path = paths[match.file.name + "\u{0}" + match.file.sha256],
                      let data = try? Data(contentsOf: path), let mime = Self.sniffImage(data) else { continue }
                switch await self.keep(data: data, mime: mime, emoji: match.emoji) {
                case .saved:
                    tally.saved += 1
                    for e in match.emoji { self.dead.remove(e.url) }
                case .already: tally.already += 1
                case .failed: tally.dead += 1
                }
            }
            self.unmatchedZipFiles = result.unmatched
            var summary = tally.summary
            if !result.unmatched.isEmpty { summary += " · \(result.unmatched.count) not in your sets" }
            self.persist()
            self.lastResult = summary
            self.progress = nil
            self.work = nil
            Self.blossom().announceStoredInVault()
        }
    }

    struct ZipRead {
        var files: [(file: EmojiVaultLogic.ZipFile, path: URL)]?
        var dir: URL?
        var tooBig = 0
        var notImage = 0
        var error: String?
    }

    /// Unzips into a fresh temp folder (Go's unzip: no paths outside it, free
    /// space kept) and hashes each image within the caps.
    nonisolated static func readZip(_ zip: URL) -> ZipRead {
        var out = ZipRead()
        let scoped = zip.startAccessingSecurityScopedResource()
        defer { if scoped { zip.stopAccessingSecurityScopedResource() } }
        let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? nil
        guard let size, size <= EmojiVaultLogic.maxZipBytes else {
            out.error = "That zip is over \(EmojiVaultLogic.maxZipBytes / 1024 / 1024) MB."
            return out
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emoji-zip-\(UUID().uuidString)", isDirectory: true)
        let copy = dir.appendingPathExtension("zip")
        out.dir = dir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: zip, to: copy)
        } catch {
            out.error = "That zip couldn't be read."
            return out
        }
        defer { try? FileManager.default.removeItem(at: copy) }
        let ok = withCStrings([copy.path, dir.path]) { p in UnzipDirectoryC(p[0], p[1]) } == 0
        guard ok else {
            out.error = "That zip couldn't be opened, or it is too big for the free space."
            return out
        }
        var files: [(EmojiVaultLogic.ZipFile, URL)] = []
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let item = walker?.nextObject() as? URL {
            let name = item.lastPathComponent
            guard !name.hasPrefix("."), !item.path.contains("/__MACOSX/"),
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let bytes = Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if bytes > EmojiVaultLogic.maxImageBytes { out.tooBig += 1; continue }
            guard files.count < EmojiVaultLogic.maxFiles, total + bytes <= EmojiVaultLogic.maxTotalBytes else { break }
            guard let data = try? Data(contentsOf: item), sniffImage(data) != nil else { out.notImage += 1; continue }
            total += bytes
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append((EmojiVaultLogic.ZipFile(name: name, sha256: sha), item))
        }
        out.files = files.map { (file: $0.0, path: $0.1) }
        return out
    }

    // MARK: Sets: add, remove, resend

    /// Adds (`on`) or removes the set at `address` on the account's 10030,
    /// built on the newest one the relays agree on (every other tag kept).
    /// The old list is kept in the vault first, and an added set's 30030 is
    /// sent again and kept.
    func setListed(_ address: String, on: Bool) async -> Bool {
        guard EmojiListParse.setRef(address) != nil, !listing.contains(address) else { return false }
        let nostr = NostrService.shared
        let me = nostr.activeHexPubkey
        guard FileNote.isHex64(me) else { return false }
        listing.insert(address)
        defer { listing.remove(address) }
        let event = await nostr.publishMergedList(kind: 10030, author: me, signAsNpub: nil, skipIfUnchanged: true) { published in
            if let published { _ = await VaultSocket.publish(published) }
            return (EmojiVaultLogic.listTags(base: published?.tags ?? [], add: on ? address : nil, remove: on ? nil : address),
                    published?.content ?? "")
        }
        guard let event else {
            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                           message: "Your emoji list couldn't be read or signed. Nothing was changed.", tone: .error)
            return false
        }
        _ = await VaultSocket.publish(event)
        if on { await resendSets(addresses: [address]) }
        EmojiListService.shared.refreshNow()
        return true
    }

    /// Each set's newest 30030 (another author's too, unchanged and still
    /// theirs) sent to the account's relays and kept in the vault.
    func resendSets(addresses: [String]) async {
        let nostr = NostrService.shared
        var events = EmojiListService.shared.setEvents
        let missing = addresses.filter { events[$0] == nil }
        if !missing.isEmpty {
            let ask = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
            events.merge(await EmojiListService.fetchSets(missing, ask: ask, nostrService: nostr)) { a, _ in a }
        }
        for address in addresses {
            guard let event = events[address] else { continue }
            _ = await VaultSocket.publish(event)
            if let data = try? JSONEncoder().encode(event),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                nostr.broadcastRawEvent(dict)
            }
        }
    }

    /// A set not in the list yet, read for the Add sheet.
    func lookUpSet(_ address: String) async -> (set: EmojiLibrary.EmojiSet, event: NostrEvent)? {
        let ask = Array(Set(ConfigService.shared.config.readRelays + MuteListStore.extraRelays))
        guard let event = await EmojiListService.fetchSets([address], ask: ask, nostrService: NostrService.shared)[address] else { return nil }
        return (EmojiListParse.set(address: address, tags: event.tags), event)
    }
}
