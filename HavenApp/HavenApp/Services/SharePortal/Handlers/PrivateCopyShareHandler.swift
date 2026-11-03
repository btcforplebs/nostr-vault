import SwiftUI

/// Keep a private copy (Share Portal, lane B). The shared file, or the
/// shared page as a PDF, is sealed on this device (PrivateCopyRecord) and
/// kept only in this device's vault: the sealed blob in its Blossom store,
/// the key in a NIP-44 record on its private relay ("/private", the one
/// drafts use: owner-only, never sent on). No outside server sees either.
struct PrivateCopyShareHandler: SharePortalHandler {
    let action = NVShareAction.privateCopy

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(PrivateCopyReviewView(intent: intent, close: close))
    }
}

/// One saved copy, as the list shows it.
struct PrivateCopyItem: Identifiable, Equatable {
    let id: String
    let savedAt: Int
    /// Nil until the record is opened (a remote signer is only asked on tap).
    var record: PrivateCopyRecord.Record?
    let ciphertext: String
}

@MainActor
enum PrivateCopyStore {
    static let privatePath = "/private"

    enum SaveError: LocalizedError {
        case missingFile, tooBig, pageFailed, readFailed, sealFailed, vaultDidNotTake, encryptFailed, signing, vaultRefused

        var errorDescription: String? {
            switch self {
            case .missingFile: return "The shared file is missing. Share it again."
            case .tooBig: return "Files over 100 MB can't be kept as a private copy yet."
            case .pageFailed: return "Couldn't turn the page into a PDF. Check the connection and try again."
            case .readFailed: return "Couldn't read the file."
            case .sealFailed: return "Couldn't encrypt the file. Nothing was saved."
            case .vaultDidNotTake: return "Your vault didn't take the file. Nothing was saved."
            case .encryptFailed: return "Couldn't encrypt the key to your account. Nothing was saved."
            case .signing: return ModePostPublisher.PublishError.signing.localizedDescription
            case .vaultRefused: return "Your vault didn't keep the record. Try again."
            }
        }
    }

    enum Step: Equatable { case rendering, sealing, saving }

    /// What the copy will hold: the first shared file, else the page.
    static func file(of intent: NVShareIntent) -> NVShareIntent.File? { intent.files.first }

    static func pageURL(of intent: NVShareIntent) -> URL? {
        guard intent.files.isEmpty, let s = intent.source.url, let url = URL(string: s),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    // MARK: Save

    /// Shares already kept, by intent id: a card swiped away after Save and
    /// shown again later opens on "Saved" instead of offering a second copy.
    private static let savedKey = "sharePortal.privateCopy.savedIntents"

    static func wasSaved(_ intent: NVShareIntent) -> Bool {
        (UserDefaults.standard.stringArray(forKey: savedKey) ?? []).contains(intent.id)
    }

    private static func markSaved(_ intent: NVShareIntent) {
        var ids = UserDefaults.standard.stringArray(forKey: savedKey) ?? []
        ids.append(intent.id)
        UserDefaults.standard.set(Array(ids.suffix(50)), forKey: savedKey)
    }

    /// Seals and keeps the copy as `lock`'s account. Returns the copy id.
    @discardableResult
    static func save(_ intent: NVShareIntent, lockedTo lock: PostingAccount.Lock,
                     step: @escaping (Step) -> Void) async throws -> String {
        let nostr = NostrService.shared
        let (plain, name, mime) = try await content(of: intent, step: step)
        guard plain.count <= PrivateCopyRecord.maxBytes else { throw SaveError.tooBig }
        step(.sealing)
        let sealed: PrivateCopyRecord.Sealed
        do { sealed = try PrivateCopyRecord.seal(plain) } catch { throw SaveError.sealFailed }
        step(.saving)
        guard nostr.activeHexPubkey == lock.hex else { throw ModePostPublisher.PublishError.accountChanged }
        let blossom = BlossomService(configService: ConfigService.shared, nostrService: nostr)
        let auth = await blossom.makeUploadAuth(sha256: sealed.x)
        guard await blossom.uploadToLocalWithRecovery(source: .data(sealed.blob), sha256: sealed.x,
                                                      contentType: "application/octet-stream", authBase64: auth) != nil else {
            throw SaveError.vaultDidNotTake
        }
        do {
            let id = try await keepRecord(intent, sealed: sealed, name: name, mime: mime, size: plain.count, lock: lock)
            markSaved(intent)
            return id
        } catch {
            // No record, no way to open it: take the sealed blob back out.
            _ = await blossom.deleteFromLocal(sha256: sealed.x)
            throw error
        }
    }

    private static func keepRecord(_ intent: NVShareIntent, sealed: PrivateCopyRecord.Sealed, name: String, mime: String,
                                   size: Int, lock: PostingAccount.Lock) async throws -> String {
        let id = UUID().uuidString.lowercased()
        let record = PrivateCopyRecord.Record(name: name, mime: mime, size: size, x: sealed.x, ox: sealed.ox,
                                              key: sealed.key, nonce: sealed.nonce, source: intent.source.url,
                                              title: intent.source.title, savedAt: Int(Date().timeIntervalSince1970))
        let ciphertext: String
        do {
            ciphertext = try await MuteListStore.encryptToSelf(PrivateCopyRecord.encode(record), me: lock.hex, nip04: false)
        } catch {
            throw SaveError.encryptFailed
        }
        // Never keep anything that is not ciphertext.
        guard PrivateCopyRecord.isCiphertext(ciphertext) else { throw SaveError.encryptFailed }
        try await keep(content: ciphertext, tags: PrivateCopyRecord.tags(id: id), lock: lock)
        return id
    }

    /// The bytes, a file name and a type. A page is rendered to PDF here.
    private static func content(of intent: NVShareIntent, step: (Step) -> Void) async throws -> (Data, String, String) {
        if let file = file(of: intent) {
            guard file.bytes <= PrivateCopyRecord.maxBytes else { throw SaveError.tooBig }
            guard let url = SharePortalInbox.shared.fileURL(for: file, of: intent) else { throw SaveError.missingFile }
            guard let data = try? Data(contentsOf: url) else { throw SaveError.readFailed }
            return (data, file.name, file.mime)
        }
        guard let page = pageURL(of: intent) else { throw SaveError.missingFile }
        step(.rendering)
        guard let pdf = await PagePDFRenderer.render(page) else { throw SaveError.pageFailed }
        return (pdf, PagePDFRenderer.fileName(title: intent.source.title, url: page), "application/pdf")
    }

    /// Signs and sends to the vault's private relay only, as `lock`.
    private static func keep(content: String, tags: [[String]], lock: PostingAccount.Lock) async throws {
        let nostr = NostrService.shared
        guard nostr.activeHexPubkey == lock.hex else { throw ModePostPublisher.PublishError.accountChanged }
        guard let event = await nostr.signEventAsync(kind: PrivateCopyRecord.kind, content: content, tags: tags) else {
            throw SaveError.signing
        }
        guard event.pubkey.lowercased() == lock.hex.lowercased() else { throw ModePostPublisher.PublishError.accountChanged }
        guard await VaultSocket.publish(event, path: privatePath, timeout: 15) else { throw SaveError.vaultRefused }
    }

    // MARK: List / open / delete

    /// This account's saved copies, newest first. Nil when the vault didn't answer.
    static func list(for hex: String) async -> [PrivateCopyItem]? {
        guard !hex.isEmpty else { return [] }
        let filter: [String: Any] = ["kinds": [PrivateCopyRecord.kind], "authors": [hex]]
        guard let events = await VaultSocket.query(path: privatePath, filter: filter, timeout: 15) else { return nil }
        var newest: [String: NostrEvent] = [:]
        for e in events where e.pubkey.lowercased() == hex.lowercased() {
            guard let id = PrivateCopyRecord.id(kind: e.kind, tags: e.tags) else { continue }
            if let have = newest[id], have.created_at >= e.created_at { continue }
            newest[id] = e
        }
        return newest.compactMap { id, e in
            PrivateCopyRecord.isCleared(content: e.content, tags: e.tags) ? nil
                : PrivateCopyItem(id: id, savedAt: Int(e.created_at), record: nil, ciphertext: e.content)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    static var usesRemoteSigner: Bool { ConfigService.shared.config.activeSigningMode() == "nip46" }

    static func readRecord(_ item: PrivateCopyItem, me hex: String) async -> PrivateCopyRecord.Record? {
        guard let plain = try? await MuteListStore.decryptToSelf(item.ciphertext, me: hex, nip04: false) else { return nil }
        return PrivateCopyRecord.decode(plain)
    }

    /// The file back, in a temporary folder named as saved. The caller
    /// deletes it when done.
    static func open(_ record: PrivateCopyRecord.Record) async throws -> URL {
        let blossom = BlossomService(configService: ConfigService.shared, nostrService: NostrService.shared)
        guard let url = URL(string: "\(await blossom.localBlossomURL())/\(record.x)") else { throw SaveError.readFailed }
        let (data, response) = try await blossom.localhostSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SaveError.readFailed }
        let plain = try PrivateCopyRecord.open(data, record: record)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("private-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(record.name)
        try plain.write(to: file, options: [.atomic, .completeFileProtection])
        return file
    }

    /// Empties the record (same slot, no key) and deletes the sealed blob.
    static func delete(_ item: PrivateCopyItem, lockedTo lock: PostingAccount.Lock) async throws {
        try await keep(content: "", tags: PrivateCopyRecord.clearedTags(id: item.id), lock: lock)
        if let x = item.record?.x {
            _ = await BlossomService(configService: ConfigService.shared, nostrService: NostrService.shared).deleteFromLocal(sha256: x)
        }
    }
}
