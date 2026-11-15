import Foundation

/// Moving locked DM photos (DMFile, NIP-17 kind 15) up and down: the ciphertext goes to the account's media servers,
/// then to a server that takes locked files when they all refuse; a received one is downloaded (capped), checked
/// against its hash, decrypted, and kept on this device as a plain file the bubble and the viewer can draw.
enum DMFileTransfer {
    /// A locked file is ciphertext with no picture type, and the default servers refuse it (Primal 415,
    /// nostr.build "file type not allowed"); nostr.download takes it (Logen 2026-11-14, as the web's
    /// LOCKED_FILE_FALLBACK). It deletes files nobody downloads within a day, so it is only ever the last try.
    static let lockedFileFallback = "https://nostr.download"

    enum TransferError: LocalizedError {
        case notUploaded, notSaved, meshOnly, http(Int), tooLarge, videoTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .notUploaded: return "The file didn't upload, so nothing was sent."
            case .notSaved: return "The file couldn't be saved on this device."
            case .meshOnly: return "This file is on a mesh address and can't be opened here."
            case .http(let code): return "The file couldn't be downloaded (HTTP \(code))."
            case .tooLarge: return "This file is too large to open."
            case .videoTooLarge(let bytes):
                return "That video is \(DMFileTransfer.megabytes(bytes)) after compressing. DMs take up to \(DMFile.maxVideoBytes / 1_048_576) MB: trim it and try again."
            }
        }
    }

    /// "12.4 MB", as the send error and the loading tile show sizes.
    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: Up

    /// Uploads `enc.cipher` as it is (never through MediaPrivacy: it isn't a picture) and returns its URL.
    @MainActor
    static func upload(_ enc: DMFile.Encrypted, configService: ConfigService, nostrService: NostrService) async throws -> URL {
        let blossom = BlossomService(configService: configService, nostrService: nostrService)
        let type = "application/octet-stream"
        if case .hosted(let url) = await blossom.uploadForPost(data: enc.cipher, sha256: enc.x, contentType: type),
           names(url, enc.x) {
            return url
        }
        let mirrors = configService.config.activeBlossomMirrors
        let fallbackHost = URL(string: lockedFileFallback)?.host
        if mirrors.contains(where: { URL(string: $0)?.host == fallbackHost }) { throw TransferError.notUploaded }
        let auth = await blossom.makeUploadAuth(sha256: enc.x)
        guard let url = await blossom.firstHostingMirror(source: .data(enc.cipher), sha256: enc.x, contentType: type,
                                                         mirrors: [lockedFileFallback], authBase64: auth, progress: nil),
              names(url, enc.x) else { throw TransferError.notUploaded }
        return url
    }

    /// A Blossom URL names its blob by hash: one that doesn't is not the file just sent.
    private static func names(_ url: URL, _ x: String) -> Bool { url.absoluteString.lowercased().contains(x) }

    // MARK: Down

    private static var directory: URL {
        var base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        // Outside the sandbox Caches is the user's shared folder: keep the plain copies under the app's own name.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil, let id = Bundle.main.bundleIdentifier {
            base = base.appendingPathComponent(id, isDirectory: true)
        }
        #endif
        return base.appendingPathComponent("dm-files", isDirectory: true)
    }

    /// Where the opened file lives on this device (DMFile.openedName), with an extension for its type.
    static func localURL(_ s: DMFile.Sealed) -> URL {
        let name = DMFile.openedName(s)
        let ext = DMFile.fileExtension(s.mime)
        return directory.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// A decrypted copy this file keeps (and only those): what the media views may read from disk.
    static func isOpenedFile(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/")
    }

    /// Removes every decrypted copy (Clear Cache, Delete Account): each is opened again from its message when needed.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func cached(_ s: DMFile.Sealed) -> URL? {
        let url = localURL(s)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps the plain bytes of a photo or video just sent, so the sender's own bubble needs no download.
    @discardableResult
    static func keep(_ plain: Data, for s: DMFile.Sealed) -> URL? {
        let url = localURL(s)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try plain.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return url
        } catch { return nil }
    }

    /// The opened photo or video on this device: downloads the ciphertext (stopping at DMFile.maxDownloadBytes),
    /// checks x, decrypts, checks ox, keeps it. `progress` hears bytes so far and the total when the server says it.
    /// Throws DMFile.Refusal or TransferError.
    static func open(_ s: DMFile.Sealed, progress: (@MainActor (Int, Int?) -> Void)? = nil) async throws -> URL {
        if let url = cached(s) { return url }
        // A .fips address must never be resolved outside the mesh (MediaCacheService.isMeshOnly).
        if MediaCacheService.isMeshOnly(s.url) { throw TransferError.meshOnly }
        let cap = DMFile.maxDownloadBytes(s)
        var request = URLRequest(url: s.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpShouldHandleCookies = false
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw TransferError.http(http.statusCode) }
        if response.expectedContentLength > Int64(cap) { throw TransferError.tooLarge }
        let total = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
        var cipher = Data()
        if let total { cipher.reserveCapacity(total) }
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in stream {
            chunk.append(byte)
            if chunk.count == 64 * 1024 {
                cipher.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                // Read in chunks and stopped at the cap: a body with no length that never ends would fill the phone.
                if cipher.count > cap { throw TransferError.tooLarge }
                if let progress, cipher.count % (512 * 1024) == 0 {
                    let got = cipher.count
                    await progress(got, total)
                }
            }
        }
        cipher.append(contentsOf: chunk)
        if cipher.count > cap { throw TransferError.tooLarge }
        let plain = try await Task.detached(priority: .userInitiated) { try DMFile.decrypt(cipher, s) }.value
        guard let url = keep(plain, for: s) else { throw TransferError.notSaved }
        return url
    }
}
