import Foundation
import CryptoKit
import os.log

/// BUD-02 Blob Descriptor returned by Blossom servers on successful upload
public struct BlobDescriptor: Codable {
    public let url: String
    public let sha256: String?
    public let size: Int?
    public let type: String?
    public let uploaded: Int?

    public init(url: String, sha256: String?, size: Int?, type: String?, uploaded: Int?) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.type = type
        self.uploaded = uploaded
    }
}

/// Source for a Blossom upload — either in-memory data or an on-disk file.
/// File uploads stream from disk, avoiding loading large videos into memory.
enum UploadSource {
    case data(Data)
    case file(URL)

    var byteCount: Int {
        switch self {
        case .data(let d):
            return d.count
        case .file(let url):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int) ?? 0
        }
    }
}

/// Handles uploading media to local and external Blossom servers
class BlossomService: @unchecked Sendable {
    let configService: ConfigService
    let nostrService: NostrService
    private let logger = Logger(subsystem: "com.bitvora.haven", category: "blossom")
    private let localhostDelegate: LocalhostTrustDelegate
    private let localhostSession: URLSession
    private let remoteSession: URLSession

    init(configService: ConfigService, nostrService: NostrService) {
        self.configService = configService
        self.nostrService = nostrService

        // Create a session that trusts self-signed certs for localhost
        // Store delegate as property to ensure it stays alive for the lifetime of the session
        let localhostConfig = URLSessionConfiguration.default
        localhostConfig.timeoutIntervalForRequest = 600  // 10 minutes
        localhostConfig.timeoutIntervalForResource = 900  // 15 minutes
        self.localhostDelegate = LocalhostTrustDelegate()
        self.localhostSession = URLSession(configuration: localhostConfig, delegate: localhostDelegate, delegateQueue: nil)

        // Create a session for remote mirrors with proper timeout configuration
        let remoteConfig = URLSessionConfiguration.default
        remoteConfig.timeoutIntervalForRequest = 600  // 10 minutes
        remoteConfig.timeoutIntervalForResource = 900  // 15 minutes
        remoteConfig.waitsForConnectivity = true  // Wait for network availability
        self.remoteSession = URLSession(configuration: remoteConfig, delegate: nil, delegateQueue: nil)
    }

    /// Mirror a message into the app's own log as well as OSLog.
    ///
    /// Everything in this file logged only to OSLog, which is invisible from
    /// the Logs screen, invisible in the log file we pull off a device, and
    /// unreadable without Console.app attached at the moment of failure. A
    /// user reporting "the upload failed" therefore came with no evidence at
    /// all, and neither did the file. These are low-frequency, one line per
    /// upload decision, so they cost nothing next to the relay's own output.
    private func appLog(_ message: String, level: String = "INFO") {
        // Two sinks on purpose. addLog reaches the in-app Logs screen, which is
        // what a user can read — but that store is in memory and a relaunch
        // wipes it. print() reaches relay.log via the stdout redirect, which is
        // the file we copy off a device after the fact. Writing to only the
        // first is how I shipped diagnostics I then could not read myself.
        RelayProcessManager.shared.addLog("Blossom: " + message, level: level)
        print("Blossom: \(message)")
    }

    /// Sign a blob's upload authorisation now, ahead of the upload.
    ///
    /// Called when an attachment is picked. The hash is known at that moment
    /// and the person is still typing, so the signer round trip — a full one,
    /// with a remote signer — is spent where they cannot feel it instead of
    /// after they tap Post. Fire-and-forget: if it has not landed by then, the
    /// upload path signs it as it always did.
    func prepareUploadAuth(sha256: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = await self?.makeUploadAuth(sha256: sha256)
        }
    }

    /// The authorisation for a blob: the pre-signed one when there is one, and
    /// otherwise one signed now.
    private func makeUploadAuth(sha256: String) async -> String? {
        // Which key will sign, asked now: an authorisation carries its signer,
        // so one cached under the account the person has since left would put
        // the blob up as that account and tie the two together at the Blossom
        // server.
        let signer = await MainActor.run { self.nostrService.activeHexPubkey }
        return await UploadAuthCache.shared.authorisation(signer: signer, sha256: sha256) { [weak self] in
            guard let self else { return nil }
            return await self.signUploadAuth(sha256: sha256)
        }
    }

    /// Sign one BUD-02 upload authorisation for a blob, to be reused for every
    /// request that blob needs.
    ///
    /// The auth event is scoped to an operation and a hash — `t: upload` and
    /// `x: <sha256>` — not to a request or a server, and the server never reads
    /// its content. So the preflight, the upload, each retry and each mirror
    /// were all signing byte-identical events and throwing them away. With a
    /// NIP-49 encrypted key every one of those is a keychain read plus a
    /// deliberately slow decrypt, stacked up at the moment the user hits post,
    /// and any one of them failing killed the upload.
    ///
    /// Caveat if a mirror is ever added that requires BUD-01's optional
    /// `server` tag: that one needs its own signature, because reuse across
    /// hosts is exactly what such a tag exists to prevent.
    ///
    /// Retries, because a momentary signer problem — a keychain read before the
    /// device has finished unlocking, a NIP-46 bunker mid-reconnect — should
    /// cost a second, not the whole upload.
    private func signUploadAuth(sha256: String) async -> (base64: String, expiresAt: Int64)? {
        let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600
        let authTags = [
            ["t", "upload"],
            ["x", sha256],
            ["expiration", String(expirationTimestamp)]
        ]
        let authContent = "Upload blob \(sha256.prefix(8))..."

        for attempt in 0..<3 {
            guard let authEvent = await nostrService.signEventAsync(kind: 24242, content: authContent, tags: authTags) else {
                let signingMode = await MainActor.run { ConfigService.shared.config.activeSigningMode() }
                appLog("could not sign the upload authorisation (mode \(signingMode)) — attempt \(attempt + 1)/3", level: "WARN")
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                return nil
            }
            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event")
                appLog("could not encode the upload authorisation", level: "ERROR")
                return nil
            }
            return (base64: authJSON.base64EncodedString(), expiresAt: expirationTimestamp)
        }
        return nil
    }

    /// Where a post's attachment ended up. Three different situations with
    /// three different remedies — they used to share one nil and one message
    /// ("check your connection"), which sent us looking at the network when
    /// the blob was sitting safely in the phone's own relay.
    enum PostUploadOutcome {
        /// An outside server accepted it; this URL goes in the note.
        case hosted(URL)
        /// In this device's relay, but no outside server took it. The post can
        /// wait for one (`MediaPostQueue`). `unreachable` is what was tried.
        case savedOnDevice(unreachable: [String])
        /// In this device's relay, and there is no outside server to try.
        case noOutsideServer
        /// Never reached this device's relay.
        case notSavedOnDevice
    }

    /// Upload a post attachment: this device's relay first, then the outside
    /// Blossom servers. `skipOutsideServers` saves locally only — used once an
    /// earlier attachment of the same post found every outside server down,
    /// so the rest don't each wait out the same retry.
    func uploadForPost(data: Data, sha256: String, contentType: String = "application/octet-stream", skipOutsideServers: Bool = false, progress: ((Double) -> Void)? = nil) async -> PostUploadOutcome {
        return await uploadAndMirror(source: .data(data), sha256: sha256, contentType: contentType, skipOutsideServers: skipOutsideServers, progress: progress)
    }

    /// File-based variant that streams the upload from disk — use for large
    /// videos so the file doesn't sit fully in memory during upload.
    func uploadForPost(fileURL: URL, sha256: String, contentType: String = "application/octet-stream", skipOutsideServers: Bool = false, progress: ((Double) -> Void)? = nil) async -> PostUploadOutcome {
        return await uploadAndMirror(source: .file(fileURL), sha256: sha256, contentType: contentType, skipOutsideServers: skipOutsideServers, progress: progress)
    }

    /// Send a blob that is already in this device's relay to the outside
    /// servers, returning the URL of the first that accepts it. What
    /// `MediaPostQueue` calls when it retries a waiting post. One pass only —
    /// the queue itself is the retry.
    func hostLocalBlob(sha256: String, contentType: String) async -> URL? {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else { return nil }
        guard await RelayProcessManager.shared.ensureRelayReady() else {
            appLog("waiting post: this device's relay is not ready yet — will retry", level: "WARN")
            return nil
        }
        let localBase = await localBlossomURL()
        guard let localURL = URL(string: "\(localBase)/\(sha256)") else { return nil }

        // Stream through a temp file: a queued video can be hundreds of MB.
        let tempURL: URL
        do {
            let (downloaded, response) = try await localhostSession.download(from: localURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                appLog("waiting post: blob \(sha256.prefix(8)) not readable from this device's relay (HTTP \(code))", level: "ERROR")
                try? FileManager.default.removeItem(at: downloaded)
                return nil
            }
            tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("queued-\(sha256)")
            try? FileManager.default.removeItem(at: tempURL)
            try FileManager.default.moveItem(at: downloaded, to: tempURL)
        } catch {
            appLog("waiting post: could not read blob \(sha256.prefix(8)) from this device's relay: \(error.localizedDescription)", level: "ERROR")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let auth = await makeUploadAuth(sha256: sha256)
        let hosted = await mirrorUploadPass(source: .file(tempURL), sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: nil)
        if let url = hosted.first {
            appLog("waiting post: \(sha256.prefix(8)) now hosted at \(url.absoluteString)")
            return url
        }
        appLog("waiting post: no outside server accepted \(sha256.prefix(8)) yet (\(mirrors))", level: "WARN")
        return nil
    }

    /// Save media to the local relay and attempt to push to configured external mirrors.
    /// Unlike uploadAndMirror, success is determined by the LOCAL relay upload only —
    /// external mirrors are attempted as a best-effort side effect but do not affect the result.
    /// Use this for "save to my relay" actions (viewer mirror button) rather than compose uploads
    /// where you need an accessible external URL to embed in a note.
    /// - Returns: true if the local relay accepted the upload, false otherwise.
    func saveToLocalRelay(data: Data, sha256: String, contentType: String = "application/octet-stream", mirrorToExternal: Bool = true) async -> Bool {
        return await saveToLocalRelay(source: .data(data), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal)
    }

    /// File-based variant that streams the upload from disk — use for large videos
    /// so the entire file doesn't sit in memory during upload.
    func saveToLocalRelay(fileURL: URL, sha256: String, contentType: String = "application/octet-stream", mirrorToExternal: Bool = true, progress: ((Double) -> Void)? = nil) async -> Bool {
        return await saveToLocalRelay(source: .file(fileURL), sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal, progress: progress)
    }

    /// Push a locally-stored blob to configured external mirrors.
    /// Downloads the blob from the local relay, then re-uploads to each external mirror.
    /// `only` limits the upload to those servers (the ones missing the blob);
    /// nil means every configured server.
    func pushLocalToMirrors(sha256: String, only: [String]? = nil) async -> Bool {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        let localURLStr = "http://127.0.0.1:\(port)/\(sha256)"
        #else
        let localURLStr = "https://localhost:\(port)/\(sha256)"
        #endif

        guard let localURL = URL(string: localURLStr) else {
            logger.error("pushLocalToMirrors: invalid local URL for \(sha256.prefix(8))")
            return false
        }

        do {
            let (data, response) = try await localhostSession.data(from: localURL)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                logger.error("pushLocalToMirrors: failed to read blob \(sha256.prefix(8)) from local relay")
                return false
            }

            let contentType = httpResponse.mimeType ?? "application/octet-stream"
            // The blob is already on this device, so upload only to the outside
            // servers. Success means at least one of them accepted it — going
            // through saveToLocalRelay returned true even when every mirror
            // failed, because its result is the local save's.
            let configured = await MainActor.run { configService.config.activeBlossomMirrors }
            let mirrors = only.map { wanted in configured.filter { wanted.contains($0) } } ?? configured
            guard !mirrors.isEmpty else {
                logger.error("pushLocalToMirrors: no outside Blossom server configured")
                return false
            }
            let auth = await makeUploadAuth(sha256: sha256)
            let accepted = await mirrorUploadPass(source: .data(data), sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: nil)
            if !accepted.isEmpty && accepted.count < mirrors.count {
                // Count, not hosts: a server may answer with a CDN URL whose
                // host differs from the one configured.
                let message = "Mirrored to \(accepted.count) of \(mirrors.count) Blossom servers"
                await MainActor.run {
                    ErrorNotificationManager.shared.show(message, icon: "exclamationmark.icloud.fill", style: .warning)
                }
            }
            return !accepted.isEmpty
        } catch {
            logger.error("pushLocalToMirrors: error reading local blob: \(error.localizedDescription)")
            return false
        }
    }

    /// Cheap liveness probe of the embedded relay's HTTP listener.
    /// Any HTTP response (including 4xx) means the server is up — an upload
    /// failure with a live server is request-specific, not a wedged relay.
    private func isLocalRelayHealthy() async -> Bool {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        #else
        guard let url = URL(string: "https://localhost:\(port)/") else { return false }
        #endif
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 2
        do {
            let (_, response) = try await localhostSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<500).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Upload to the local relay with automatic restart recovery.
    /// A restart is the last resort: it cycles the embedded Go relay and
    /// BadgerDB, so it only happens when the relay is provably unreachable —
    /// not for request-specific upload failures, and not right after the
    /// system woke from sleep (gracefulRestart enforces coalescing, a
    /// cooldown, and the post-wake grace window).
    private func uploadToLocalWithRecovery(source: UploadSource, sha256: String, contentType: String, authBase64: String? = nil) async -> URL? {
        // Flags and a real HTTP answer: a relay that reads as running but
        // lost its socket in the background goes straight to the restart.
        var relayReady = await RelayProcessManager.shared.ensureRelayServing()
        if !relayReady {
            logger.warning("uploadToLocalWithRecovery: relay not ready, attempting graceful restart")
            relayReady = await RelayProcessManager.shared.gracefulRestart()
            guard relayReady else {
                logger.error("uploadToLocalWithRecovery: relay still not ready after restart")
                return nil
            }
        }

        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        let localURLStr = "http://127.0.0.1:\(port)"
        #else
        let localURLStr = "https://localhost:\(port)"
        #endif

        // First attempt
        if let result = await uploadToServer(source: source, url: localURLStr, sha256: sha256, contentType: contentType, useLocalhostSession: true, authBase64: authBase64) {
            return result
        }

        // Upload failed. If the relay is still answering HTTP, the failure
        // is request-specific — retry once without restarting.
        if await isLocalRelayHealthy() {
            logger.warning("uploadToLocalWithRecovery: upload failed but relay is healthy — retrying without restart")
            return await uploadToServer(source: source, url: localURLStr, sha256: sha256, contentType: contentType, useLocalhostSession: true, authBase64: authBase64)
        }

        // Relay is unreachable — restart and retry once.
        logger.warning("uploadToLocalWithRecovery: local relay unreachable, restarting for recovery")
        let restarted = await RelayProcessManager.shared.gracefulRestart()
        guard restarted else {
            logger.error("uploadToLocalWithRecovery: relay restart failed, cannot recover")
            return nil
        }

        let retryPort = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        let retryURL = "http://127.0.0.1:\(retryPort)"
        #else
        let retryURL = "https://localhost:\(retryPort)"
        #endif

        return await uploadToServer(source: source, url: retryURL, sha256: sha256, contentType: contentType, useLocalhostSession: true, authBase64: authBase64)
    }

    private func saveToLocalRelay(source: UploadSource, sha256: String, contentType: String, mirrorToExternal: Bool, progress: ((Double) -> Void)? = nil) async -> Bool {
        let auth = await makeUploadAuth(sha256: sha256)
        let localResult = await uploadToLocalWithRecovery(source: source, sha256: sha256, contentType: contentType, authBase64: auth)
        guard localResult != nil else {
            logger.error("saveToLocalRelay: local upload failed after recovery attempt")
            return false
        }
        logger.info("saveToLocalRelay: local upload succeeded (\(source.byteCount) bytes)")

        // Push to external mirrors — awaited to ensure uploads complete before returning.
        // Previously fire-and-forget, which caused mirrors to silently fail on iOS
        // when the app was backgrounded or the view was dismissed.
        // Skipped during bulk sync (mirrorToExternal: false) to avoid N×M uploads.
        let mirrors = mirrorToExternal ? await MainActor.run { configService.config.activeBlossomMirrors } : []
        if !mirrors.isEmpty {
            logger.info("saveToLocalRelay: mirroring to \(mirrors.count) external server(s)")
            let failedMirrors: [String] = await withTaskGroup(of: (String, Bool).self, returning: [String].self) { group in
                for (index, mirror) in mirrors.enumerated() {
                    group.addTask {
                        let parsed = URL(string: mirror)
                        let useLocal = parsed.map { self.isLocalhost($0) } ?? false
                        let progressHandler = (index == 0) ? progress : nil

                        // BUD-06: Preflight check — skip mirror if server rejects
                        let accepted = await self.preflightCheck(
                            url: mirror, sha256: sha256,
                            contentLength: source.byteCount, contentType: contentType,
                            useLocalhostSession: useLocal, authBase64: auth
                        )
                        guard accepted else {
                            self.logger.info("saveToLocalRelay: skipping \(mirror) — BUD-06 preflight rejected")
                            return (mirror, false)
                        }

                        let result = await self.uploadToServer(source: source, url: mirror, sha256: sha256, contentType: contentType, useLocalhostSession: useLocal, authBase64: auth, progress: progressHandler)
                        if result != nil {
                            self.logger.info("saveToLocalRelay: mirrored to \(mirror)")
                        } else {
                            self.logger.warning("saveToLocalRelay: mirror to \(mirror) failed")
                        }
                        return (mirror, result != nil)
                    }
                }
                var failed: [String] = []
                for await (mirror, success) in group {
                    if !success {
                        failed.append(mirror)
                    }
                }
                return failed
            }
            logger.info("saveToLocalRelay: external mirror uploads finished")

            if !failedMirrors.isEmpty {
                let hostNames = failedMirrors.compactMap { URL(string: $0)?.host }.joined(separator: ", ")
                let message = failedMirrors.count == mirrors.count
                    ? "Saved locally, but all blossom mirrors failed"
                    : "Saved locally, mirror failed: \(hostNames)"
                await MainActor.run {
                    ErrorNotificationManager.shared.show(message, icon: "exclamationmark.icloud.fill", style: .warning)
                }
            }
        }

        return true
    }

    private func uploadAndMirror(source: UploadSource, sha256: String, contentType: String, skipOutsideServers: Bool, progress: ((Double) -> Void)?) async -> PostUploadOutcome {
        // One signature for this blob, reused by the local save, the preflight,
        // every retry and every mirror. nil means the key is genuinely
        // unavailable after three tries — each call below then signs its own,
        // which will fail the same way but keeps the failure local.
        let auth = await makeUploadAuth(sha256: sha256)

        // Step 1: Upload to local Blossom first (with restart recovery)
        guard await uploadToLocalWithRecovery(source: source, sha256: sha256, contentType: contentType, authBase64: auth) != nil else {
            logger.error("uploadAndMirror: failed to upload to local relay after recovery attempt")
            appLog("post upload FAILED at stage 1 of 2 — the blob never reached this device's own relay", level: "ERROR")
            return .notSavedOnDevice
        }

        // Step 2: Get mirrors on main actor
        let mirrors = await MainActor.run {
            configService.config.activeBlossomMirrors
        }

        logger.info("Found \(mirrors.count) configured Blossom mirrors: \(mirrors)")

        guard !mirrors.isEmpty else {
            appLog("post upload stopped at stage 2 of 2 — saved on this device, but no outside Blossom server is configured", level: "ERROR")
            return .noOutsideServer
        }

        if skipOutsideServers {
            appLog("saved \(sha256.prefix(8)) on this device only — an earlier attachment found every outside server down")
            return .savedOnDevice(unreachable: mirrors)
        }

        // Step 3: Upload to external mirrors concurrently using standard BUD-02 protocol
        var mirrorURLs = await mirrorUploadPass(source: source, sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: progress)

        // A sleeping mirror host (e.g. the Mac relay over LAN/Tailscale) is often
        // woken *by* the first pass's connection attempts (wake-on-network) but
        // isn't up fast enough to serve it. Wait and retry the whole pass once
        // before handing the post to the queue.
        if mirrorURLs.isEmpty {
            logger.warning("All Blossom mirrors failed — retrying once in 10s in case a sleeping host is still waking")
            appLog("first mirror pass failed for all of \(mirrors) — retrying once in 10s", level: "WARN")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            mirrorURLs = await mirrorUploadPass(source: source, sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: progress)
        }

        // Return first successful external mirror
        if let externalURL = mirrorURLs.first {
            logger.info("Using external Blossom mirror: \(externalURL.absoluteString)")
            appLog("post upload ok — mirrored to \(externalURL.absoluteString)")
            return .hosted(externalURL)
        }

        appLog("post upload paused at stage 2 of 2 — saved on this device, no outside server accepted it after two passes; the post will wait for one", level: "WARN")
        return .savedOnDevice(unreachable: mirrors)
    }

    /// One concurrent BUD-02 upload pass over all configured mirrors.
    /// Returns the URLs of every mirror that accepted the blob.
    private func mirrorUploadPass(source: UploadSource, sha256: String, contentType: String, mirrors: [String], authBase64: String?, progress: ((Double) -> Void)?) async -> [URL] {
        logger.debug("Attempting to mirror to: \(mirrors.description)")
        return await withTaskGroup(of: (Int, String, URL?).self) { group in
            for (index, mirrorURL) in mirrors.enumerated() {
                group.addTask {
                    // Only report progress for the first remote mirror to avoid progress jitter
                    let progressHandler = (index == 0) ? progress : nil
                    let parsed = URL(string: mirrorURL)
                    let useLocalSession = parsed.map { self.isLocalhost($0) } ?? false

                    // BUD-06: Preflight check — skip mirror if server rejects
                    let accepted = await self.preflightCheck(
                        url: mirrorURL, sha256: sha256,
                        contentLength: source.byteCount, contentType: contentType,
                        useLocalhostSession: useLocalSession, authBase64: authBase64
                    )
                    guard accepted else {
                        self.logger.info("BUD-06: Skipping mirror \(mirrorURL) — preflight rejected")
                        return (index, mirrorURL, nil)
                    }

                    let result = await self.uploadToServer(source: source, url: mirrorURL, sha256: sha256, contentType: contentType, useLocalhostSession: useLocalSession, authBase64: authBase64, progress: progressHandler)
                    return (index, mirrorURL, result)
                }
            }

            var successfulMirrors: [(index: Int, url: URL)] = []
            for await (index, mirrorURL, result) in group {
                if let url = result {
                    self.logger.info("Mirror upload succeeded for \(mirrorURL): \(url.absoluteString)")
                    successfulMirrors.append((index, url))
                } else {
                    self.logger.warning("Mirror upload failed for \(mirrorURL)")
                }
            }
            // In the order the servers are configured, not the order they
            // answered: callers post the first URL, and the list order is the
            // user's preference. Fastest-first made it whichever server won
            // the race that time.
            return successfulMirrors.sorted { $0.index < $1.index }.map(\.url)
        }
    }

    /// Fire a cheap unauthenticated HEAD at every configured mirror so sleeping
    /// hosts (notably a Mac relay woken via wake-on-network / the Bonjour sleep
    /// proxy) start waking as soon as the composer opens, instead of during the
    /// post itself. Responses are ignored — this is connection warming only.
    func prewarmMirrors() async {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for mirror in mirrors {
                guard let url = URL(string: mirror) else { continue }
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 20
                    let session = self.isLocalhost(url) ? self.localhostSession : self.remoteSession
                    _ = try? await session.data(for: request)
                }
            }
        }
    }

    /// Upload media to a specific Blossom server with retry logic
    /// Uses Blossom HTTP Auth (kind 24242, per BUD-01 spec)
    /// `authBase64` is a pre-signed BUD-02 authorisation from makeUploadAuth,
    /// reused across the preflight, the retries and every mirror for one blob.
    /// Passing nil makes this sign its own, for callers that upload a single
    /// blob to a single server.
    private func uploadToServer(source: UploadSource, url: String, sha256: String, contentType: String, useLocalhostSession: Bool, authBase64: String? = nil, progress: ((Double) -> Void)? = nil) async -> URL? {
        let maxRetries = 3
        let parsedURL = URL(string: url)
        // isOnDeviceRelay: strict localhost only — used for response parsing (skip BlobDescriptor)
        let isOnDeviceRelay = parsedURL.map { host in
            guard let h = host.host?.lowercased() else { return false }
            return h == "localhost" || h == "127.0.0.1" || h == "0.0.0.0"
        } ?? false
        // isLocalNetwork: includes LAN — used for HTTPS skip (don't force https on LAN)
        let isLocalNetwork = parsedURL.map { isLocalhost($0) } ?? false

        for attempt in 0..<maxRetries {
            guard var serverURL = URL(string: url) else {
                logger.error("Invalid Blossom server URL: \(url)")
                return nil
            }

            // Ensure HTTPS for remote servers (skip for localhost and LAN)
            if serverURL.scheme == "http" && !isLocalNetwork {
                var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url {
                    serverURL = secureURL
                }
            }

            // BUD-02 standard: PUT /upload for all servers (local khatru/blossom + external)
            let uploadURL = serverURL.appendingPathComponent("upload")

            // One authorisation per blob, signed by the caller and reused for
            // the preflight, every retry and every mirror. See makeUploadAuth.
            let auth: String
            if let provided = authBase64 {
                auth = provided
            } else if let signed = await makeUploadAuth(sha256: sha256) {
                auth = signed
            } else {
                logger.error("Failed to create Blossom auth event for \(url)")
                return nil
            }

            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")  // Nostr auth scheme per Blossom spec
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            // Explicit Content-Length for BUD-02 compliance — ensures servers know the
            // full payload size upfront regardless of upload source type.
            let bodySize = source.byteCount
            request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")
            request.timeoutInterval = 600  // 10 minutes for large file uploads to external mirrors

            logger.debug("Uploading to \(uploadURL.absoluteString), Blossom auth event kind 24242, data size: \(bodySize) bytes")

            do {
                // Use the appropriate URLSession
                let session = useLocalhostSession ? localhostSession : remoteSession
                let delegate = progress.map { UploadProgressDelegate(progressHandler: $0) }
                let (responseData, response): (Data, URLResponse)
                switch source {
                case .data(let bytes):
                    (responseData, response) = try await session.upload(for: request, from: bytes, delegate: delegate)
                case .file(let fileURL):
                    (responseData, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
                }

                if let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) {
                    // For external/mirror servers, parse BUD-02 Blob Descriptor for the canonical URL
                    if !isOnDeviceRelay, let descriptor = try? JSONDecoder().decode(BlobDescriptor.self, from: responseData),
                       let downloadURL = URL(string: descriptor.url) {
                        logger.info("Successfully uploaded to \(url): \(descriptor.url)")
                        return downloadURL
                    }
                    // Fallback (local on-device relay or unparseable response): construct URL
                    let fileURL = serverURL.appendingPathComponent(sha256)
                    logger.info("Successfully uploaded to \(url): \(fileURL.absoluteString)")
                    return fileURL
                } else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let responseBody = String(data: responseData, encoding: .utf8) ?? "(binary)"
                    logger.warning("Upload to \(url) attempt \(attempt + 1)/\(maxRetries) failed with status: \(statusCode), response: \(responseBody)")
                    appLog("upload to \(url) attempt \(attempt + 1)/\(maxRetries) — HTTP \(statusCode): \(responseBody.prefix(200))", level: "WARN")

                    // Retry on transient errors (5xx)
                    if attempt < maxRetries - 1 && statusCode >= 500 {
                        let backoffNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                        try? await Task.sleep(nanoseconds: backoffNs)
                        continue
                    }
                    return nil
                }
            } catch {
                let errorDesc = error.localizedDescription
                logger.error("Upload to \(url) attempt \(attempt + 1)/\(maxRetries) caught error: \(errorDesc), error type: \(type(of: error))")
                appLog("upload to \(url) attempt \(attempt + 1)/\(maxRetries) failed: \(errorDesc)", level: "WARN")

                if let urlError = error as? URLError {
                    logger.error("URLError code: \(urlError.code.rawValue)")
                }

                // Retry on network errors
                if attempt < maxRetries - 1 {
                    let backoffNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: backoffNs)
                    continue
                }
                return nil
            }
        }

        logger.error("Upload to \(url) failed after \(maxRetries) attempts")
        return nil
    }

    // MARK: - BUD-06: Upload Preflight

    /// BUD-06: Pre-flight check via HEAD /upload before attempting a PUT upload.
    /// Returns true if the server would accept the upload, false if the mirror should be skipped.
    /// Fail-open: returns true on network errors or if the server doesn't support BUD-06.
    private func preflightCheck(url: String, sha256: String, contentLength: Int, contentType: String, useLocalhostSession: Bool, authBase64: String? = nil) async -> Bool {
        guard var serverURL = URL(string: url) else { return true }

        let isLocalNetwork = isLocalhost(serverURL)
        if serverURL.scheme == "http" && !isLocalNetwork {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secureURL = components?.url { serverURL = secureURL }
        }

        let uploadURL = serverURL.appendingPathComponent("upload")

        // Reuses the blob's single authorisation — the preflight used to sign
        // its own byte-identical copy. Fail-open if we have none: this check is
        // optional, and refusing to upload because a signature for an optional
        // check could not be produced would be the tail wagging the dog.
        let auth: String
        if let provided = authBase64 {
            auth = provided
        } else if let signed = await makeUploadAuth(sha256: sha256) {
            auth = signed
        } else {
            appLog("no authorisation available for the preflight of \(url) — proceeding to the upload anyway", level: "WARN")
            return true
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "HEAD"
        request.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue(sha256, forHTTPHeaderField: "X-SHA-256")
        request.setValue(String(contentLength), forHTTPHeaderField: "X-Content-Length")
        request.setValue(contentType, forHTTPHeaderField: "X-Content-Type")
        request.timeoutInterval = 15

        do {
            let session = useLocalhostSession ? localhostSession : remoteSession
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.debug("BUD-06: Preflight OK for \(url)")
                    return true
                }
                // 404/405 mean the server simply doesn't implement HEAD /upload
                // (BUD-06 is optional) — proceed with the real upload rather than
                // permanently skipping the mirror.
                if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                    logger.debug("BUD-06: \(url) does not implement HEAD /upload — proceeding without preflight")
                    return true
                }
                let reason = httpResponse.value(forHTTPHeaderField: "X-Reason") ?? "none"
                // A 5xx, a timeout or a rate-limit is the server failing to
                // answer, not the server declining this blob. BUD-06 exists so
                // a server can say "not this file" — too big, wrong type, not
                // allowed — and only those deserve to skip the mirror. Treating
                // a cold origin's 502 as a refusal meant the upload was never
                // even attempted, which is indistinguishable to the user from
                // the upload failing, and it recovers by itself on the next try.
                if httpResponse.statusCode >= 500 || httpResponse.statusCode == 408 || httpResponse.statusCode == 429 {
                    logger.info("BUD-06: \(url) could not answer preflight (status \(httpResponse.statusCode)) — attempting the upload anyway")
                    appLog("preflight inconclusive for \(url) — HTTP \(httpResponse.statusCode), attempting upload anyway", level: "WARN")
                    return true
                }
                logger.info("BUD-06: Preflight rejected by \(url) — status \(httpResponse.statusCode), reason: \(reason)")
                appLog("preflight rejected by \(url) — HTTP \(httpResponse.statusCode), reason: \(reason)", level: "WARN")
                return false
            }
        } catch {
            logger.warning("BUD-06: Preflight network error for \(url): \(error.localizedDescription)")
            appLog("preflight network error for \(url): \(error.localizedDescription) — proceeding anyway", level: "WARN")
        }
        return true // Fail-open
    }

    // MARK: - Download & Mirror from External Servers

    /// Download media from any URL and store it in the local Blossom server.
    /// Computes SHA256 from the downloaded data — works with any remote server, not just configured mirrors.
    /// - Parameters:
    ///   - url: The full URL to download from (e.g., https://blossom.primal.net/abc123.jpg)
    ///   - mirrorToExternal: Whether to also push the blob to configured external Blossom mirrors.
    ///     Pass `true` for user-initiated "Mirror to Blossom" actions so all configured servers receive the blob.
    ///     Defaults to `false` for internal/batch operations where only local storage is needed.
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromURL(url: URL, mirrorToExternal: Bool = false) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120  // 2 minutes — 30s was too short for video files

        do {
            let (data, response) = try await remoteSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger.warning("Download from \(url.absoluteString) failed with status \(status)")
                return false
            }

            // Compute SHA256 from downloaded data
            let hash = SHA256.hash(data: data)
            let sha256 = hash.compactMap { String(format: "%02x", $0) }.joined()
            let contentType = httpResponse.mimeType ?? "application/octet-stream"

            // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth).
            let success = await saveToLocalRelay(data: data, sha256: sha256, contentType: contentType, mirrorToExternal: mirrorToExternal)
            if success {
                logger.info("Successfully mirrored \(sha256.prefix(8)) from \(url.host ?? "remote") via local relay upload")
            }
            return success
        } catch {
            logger.warning("Download from \(url.absoluteString) error: \(error.localizedDescription)")
            return false
        }
    }

    /// Download a blob from configured mirrors and store it in the local Blossom server
    /// - Parameter sha256: The SHA256 hash of the blob to download
    /// - Returns: true if the blob was successfully downloaded and stored locally
    func downloadFromMirrors(sha256: String) async -> Bool {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured for download")
            return false
        }

        // Try each mirror until one succeeds
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else { continue }

            // Ensure HTTPS for remote servers
            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url {
                    mirrorURL = secureURL
                }
            }

            let blobURL = mirrorURL.appendingPathComponent(sha256)
            var request = URLRequest(url: blobURL)
            request.timeoutInterval = 30

            do {
                let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    logger.warning("Download from \(mirror)/\(sha256.prefix(8)) failed with status \(status)")
                    continue
                }

                // Verify SHA256
                let hash = SHA256.hash(data: data)
                let computedHash = hash.compactMap { String(format: "%02x", $0) }.joined()
                guard computedHash == sha256 else {
                    logger.error("SHA256 mismatch downloading from \(mirror): expected \(sha256.prefix(16)), got \(computedHash.prefix(16))")
                    continue
                }

                let contentType = httpResponse.mimeType ?? "application/octet-stream"

                // Upload to local relay via BUD-02 spec (HTTP PUT with kind 24242 auth).
                // Skip external mirroring — the blob came FROM a configured mirror.
                let success = await saveToLocalRelay(data: data, sha256: sha256, contentType: contentType, mirrorToExternal: false)
                if success {
                    logger.info("Successfully mirrored \(sha256.prefix(8)) from \(mirror) via local relay upload")
                    return true
                } else {
                    logger.warning("Local relay rejected upload of \(sha256.prefix(8)) from \(mirror)")
                    continue
                }
            } catch {
                logger.warning("Download from \(mirror)/\(sha256.prefix(8)) error: \(error.localizedDescription)")
                continue
            }
        }

        logger.error("Failed to download \(sha256.prefix(8)) from any mirror")
        return false
    }

    /// Mirror all owner media from external Blossom servers to local storage
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorAllFromExternal(progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let ownerPubkey = await MainActor.run { nostrService.ownerHexPubkey }
        let whitelistedPubkeys = await MainActor.run { configService.whitelistedHexPubkeys }
        let allPubkeys = ([ownerPubkey] + Array(whitelistedPubkeys)).filter { !$0.isEmpty }

        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured")
            return 0
        }

        // Get local blob hashes
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
        let localHashes: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(atPath: blossomDir.path) {
            localHashes = Set(files.filter { !$0.starts(with: ".") && $0 != "LOCK" })
        } else {
            localHashes = []
        }
        logMessage?("Local storage has \(localHashes.count) existing blob(s)", "INFO")

        // Discover blobs from mirrors using BUD-02 /list endpoint with cursor pagination
        // Queries each pubkey (owner + whitelisted) on each mirror
        var remoteBlobHashes: Set<String> = []
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else { continue }

            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url { mirrorURL = secureURL }
            }

            logMessage?("Querying \(mirror) for blob list...", "INFO")

            // Create a BUD-02 auth event (kind 24242) for the list operation so servers
            // that require authentication return blob lists instead of empty/403.
            let listExpiration = Int64(Date().timeIntervalSince1970) + 3600
            let listAuthTags = [
                ["t", "list"],
                ["expiration", String(listExpiration)]
            ]
            let listAuthEvent = await nostrService.signEventAsync(kind: 24242, content: "List blobs", tags: listAuthTags)
            var listAuthHeader: String? = nil
            if let authEvent = listAuthEvent,
               let authJSON = try? JSONEncoder().encode(authEvent) {
                listAuthHeader = "Nostr \(authJSON.base64EncodedString())"
            }

            for pubkey in allPubkeys {
                let baseListURL = mirrorURL.appendingPathComponent("list").appendingPathComponent(pubkey)
                var totalForPubkey = 0

                var request = URLRequest(url: baseListURL)
                request.timeoutInterval = 30
                if let authHeader = listAuthHeader {
                    request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                }

                do {
                    let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                    let (data, response) = try await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        logMessage?("List \(mirror)/list/\(pubkey.prefix(8))... returned HTTP \(code)", "WARN")
                        continue
                    }

                    guard let descriptors = try? JSONDecoder().decode([BlobDescriptor].self, from: data),
                          !descriptors.isEmpty else { continue }

                    for desc in descriptors {
                        if let hash = desc.sha256 {
                            remoteBlobHashes.insert(hash)
                        }
                    }
                    totalForPubkey = descriptors.count
                } catch {
                    logger.warning("Failed to list blobs from \(mirror) for \(pubkey.prefix(8)): \(error.localizedDescription)")
                    logMessage?("Failed to list blobs from \(mirror): \(error.localizedDescription)", "ERROR")
                }

                if totalForPubkey > 0 {
                    let label = pubkey == ownerPubkey ? "owner" : "whitelisted \(pubkey.prefix(8))"
                    logger.info("Found \(totalForPubkey) blobs on \(mirror) for \(label)")
                    logMessage?("Found \(totalForPubkey) blob(s) on \(mirror) for \(label)", "INFO")
                }
            }
        }

        // Find blobs that exist remotely but not locally
        let missingHashes = remoteBlobHashes.subtracting(localHashes)
        guard !missingHashes.isEmpty else {
            logger.info("All remote blobs already mirrored locally")
            logMessage?("All \(remoteBlobHashes.count) remote blob(s) already exist locally", "INFO")
            return 0
        }

        logger.info("Found \(missingHashes.count) blobs to mirror from external servers")
        logMessage?("\(missingHashes.count) blob(s) missing locally — downloading from mirrors...", "INFO")
        let sortedHashes = Array(missingHashes).sorted()
        var mirrored = 0
        var completedCount = 0
        let total = sortedHashes.count

        await withTaskGroup(of: Bool.self) { group in
            var queued = 0
            for hash in sortedHashes {
                if queued >= 4 {
                    if let success = await group.next() {
                        completedCount += 1
                        if success {
                            mirrored += 1
                            logMessage?("Downloaded \(hash.prefix(12))... (\(completedCount)/\(total))", "INFO")
                        } else {
                            logMessage?("Failed to download \(hash.prefix(12))... (\(completedCount)/\(total))", "WARN")
                        }
                        progress?(completedCount, total)
                    }
                    // Throttle to avoid overwhelming the relay
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                group.addTask {
                    await self.downloadFromMirrors(sha256: hash)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success {
                    mirrored += 1
                    logMessage?("Downloaded \(sortedHashes[min(completedCount - 1, sortedHashes.count - 1)].prefix(12))... (\(completedCount)/\(total))", "INFO")
                } else {
                    logMessage?("Failed to download blob (\(completedCount)/\(total))", "WARN")
                }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) blobs from external servers")
        logMessage?("Server mirror phase: \(mirrored)/\(total) blob(s) downloaded successfully", "INFO")
        return mirrored
    }

    /// Mirror media from note events (kind 1063 file metadata) that aren't already stored locally.
    /// Unlike mirrorAllFromExternal (which only checks configured mirrors via BUD-04), this scans
    /// the actual media URLs from synced notes — handling media on any server (e.g., Primal's blossom).
    /// - Parameter noteMedia: The array of MediaItem from nostrService.noteMedia
    /// - Parameter progress: Callback with (completed, total) counts
    /// - Returns: Number of newly mirrored blobs
    func mirrorFromNoteMedia(_ noteMedia: [MediaItem], progress: ((Int, Int) -> Void)? = nil, logMessage: ((String, String) -> Void)? = nil) async -> Int {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let ownerPubkey = await MainActor.run { nostrService.ownerHexPubkey }
        let whitelistedPubkeys = await MainActor.run { configService.whitelistedHexPubkeys }

        // Get local blob hashes
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)
        let localHashes: Set<String>
        if let files = try? FileManager.default.contentsOfDirectory(atPath: blossomDir.path) {
            localHashes = Set(files.filter { !$0.starts(with: ".") && $0 != "LOCK" })
        } else {
            localHashes = []
        }

        // Find remote media URLs from owner or whitelisted accounts that aren't stored locally
        var urlsToMirror: [URL] = []
        for item in noteMedia {
            guard let pubkey = item.pubkey,
                  pubkey == ownerPubkey ||
                  whitelistedPubkeys.contains(pubkey) else { continue }
            // Skip local URLs
            let host = item.url.host?.lowercased() ?? ""
            if host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0" { continue }

            // Extract hash from URL to check if already local
            let lastComponent = item.url.deletingPathExtension().lastPathComponent
            if lastComponent.count == 64 && lastComponent.allSatisfy({ $0.isHexDigit }) {
                if localHashes.contains(lastComponent) { continue }
            }

            urlsToMirror.append(item.url)
        }

        guard !urlsToMirror.isEmpty else {
            logger.info("No missing media found in note events")
            logMessage?("All note media already exists locally", "INFO")
            return 0
        }

        logger.info("Found \(urlsToMirror.count) media items from notes to mirror locally")
        logMessage?("\(urlsToMirror.count) media item(s) missing locally — downloading...", "INFO")
        var mirrored = 0
        var completedCount = 0
        let total = urlsToMirror.count

        // Process concurrently with a limit of 4 simultaneous downloads
        await withTaskGroup(of: Bool.self) { group in
            var queued = 0
            for url in urlsToMirror {
                if queued >= 4 {
                    if let success = await group.next() {
                        completedCount += 1
                        if success {
                            mirrored += 1
                            logMessage?("Mirrored \(url.lastPathComponent.prefix(20))... from \(url.host ?? "remote") (\(completedCount)/\(total))", "INFO")
                        } else {
                            logMessage?("Failed \(url.lastPathComponent.prefix(20))... from \(url.host ?? "remote") (\(completedCount)/\(total))", "WARN")
                        }
                        progress?(completedCount, total)
                    }
                    // Throttle to avoid overwhelming the relay
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                group.addTask {
                    await self.downloadFromURL(url: url)
                }
                queued += 1
            }
            for await success in group {
                completedCount += 1
                if success {
                    mirrored += 1
                    logMessage?("Mirrored media (\(completedCount)/\(total))", "INFO")
                } else {
                    logMessage?("Failed to mirror media (\(completedCount)/\(total))", "WARN")
                }
                progress?(completedCount, total)
            }
        }

        progress?(total, total)
        logger.info("Mirrored \(mirrored)/\(total) media from note events")
        logMessage?("Note media phase: \(mirrored)/\(total) item(s) downloaded successfully", "INFO")
        return mirrored
    }

    /// Returns the local Blossom server URL string
    private func localBlossomURL() async -> String {
        let port = await MainActor.run { configService.config.relayPort }
        #if os(macOS)
        return "http://127.0.0.1:\(port)"
        #else
        return "https://localhost:\(port)"
        #endif
    }

    /// Which mirrors a delete reached. A delete is only done when `failed` is
    /// empty: the file is still public on every server listed there.
    struct MirrorDeleteResult {
        var deleted: [String] = []
        var failed: [String] = []

        var allDeleted: Bool { failed.isEmpty && !deleted.isEmpty }

        /// Hosts still holding the file, for the banner ("blossom.primal.net").
        var failedHosts: [String] {
            failed.map { URL(string: $0)?.host ?? $0 }
        }
    }

    /// What a Delete everywhere left behind, or nil when nothing is left.
    /// Names each place so a partial delete can't pass for a full one.
    static func deleteEverywhereLeftover(localDeleted: Bool, mirrors: MirrorDeleteResult) -> String? {
        var places = mirrors.failedHosts
        if !localDeleted { places.append("this device") }
        guard !places.isEmpty else { return nil }
        return "Still on " + ListFormatter.localizedString(byJoining: places)
    }

    /// Delete media from mirrors only
    /// - Parameter sha256: The SHA256 hash of the media to delete
    /// - Returns: true only if every mirror deleted it (or already lacked it)
    func deleteFromMirrors(sha256: String) async -> Bool {
        await deleteFromMirrorsReport(sha256: sha256).allDeleted
    }

    /// Delete media from every mirror and report each one. One mirror
    /// succeeding used to count as success, so a file left on two of three
    /// servers was reported as deleted.
    func deleteFromMirrorsReport(sha256: String) async -> MirrorDeleteResult {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else {
            logger.warning("No Blossom mirrors configured for deletion")
            return MirrorDeleteResult()
        }

        var result = MirrorDeleteResult()
        for mirror in mirrors {
            guard var mirrorURL = URL(string: mirror) else {
                result.failed.append(mirror)
                continue
            }

            // Ensure HTTPS for remote servers
            if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
                var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if let secureURL = components?.url {
                    mirrorURL = secureURL
                }
            }

            let deleteURL = mirrorURL.appendingPathComponent(sha256)
            var request = URLRequest(url: deleteURL)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 30

            // Create Blossom auth event for deletion per BUD-02 spec
            let expirationTimestamp = Int64(Date().timeIntervalSince1970) + 3600
            let authTags = [
                ["t", "delete"],
                ["x", sha256],
                ["u", deleteURL.absoluteString],
                ["expiration", String(expirationTimestamp)]
            ]

            let authContent = "Delete blob \(sha256.prefix(8))..."

            guard let authEvent = await nostrService.signEventAsync(kind: 24242, content: authContent, tags: authTags) else {
                logger.error("Failed to create Blossom auth event for deletion from \(mirror)")
                result.failed.append(mirror)
                continue
            }

            guard let authJSON = try? JSONEncoder().encode(authEvent) else {
                logger.error("Failed to encode auth event for deletion from \(mirror)")
                result.failed.append(mirror)
                continue
            }

            let authBase64 = authJSON.base64EncodedString()
            request.setValue("Nostr \(authBase64)", forHTTPHeaderField: "Authorization")

            do {
                let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...204).contains(status) {
                    logger.info("Successfully deleted \(sha256.prefix(8)) from mirror \(mirror)")
                    result.deleted.append(mirror)
                } else if status == 404 {
                    logger.info("Confirmed \(sha256.prefix(8)) is already absent from mirror \(mirror)")
                    result.deleted.append(mirror)
                } else {
                    let bodyString = String(data: data, encoding: .utf8) ?? "(binary/empty)"
                    logger.warning("Failed to delete from \(mirror) with status \(status), response: \(bodyString)")
                    result.failed.append(mirror)
                }
            } catch {
                logger.error("Error deleting from \(mirror): \(error.localizedDescription)")
                result.failed.append(mirror)
            }
        }

        return result
    }

    /// Delete media from local Blossom storage
    /// - Parameter sha256: The SHA256 hash of the media to delete
    /// - Returns: true if the file is gone (deleted, or was never stored here)
    func deleteFromLocal(sha256: String) async -> Bool {
        let relayDataDir = await MainActor.run { configService.relayDataDir }
        let blossomPath = await MainActor.run { configService.config.blossomPath }
        let blossomDir = relayDataDir.appendingPathComponent(blossomPath)

        // Try to delete the exact hash
        let fileURL = blossomDir.appendingPathComponent(sha256)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                logger.info("Successfully deleted \(sha256.prefix(8)) from local storage")
                return true
            } catch {
                logger.error("Failed to delete from local storage: \(error.localizedDescription)")
                return false
            }
        }

        // Try to find file with hash + extension (e.g., sha256.jpg)
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: blossomDir.path)
            for filename in contents {
                if filename.hasPrefix(sha256) && filename.count > 64 {
                    let extensionedURL = blossomDir.appendingPathComponent(filename)
                    try FileManager.default.removeItem(at: extensionedURL)
                    logger.info("Successfully deleted \(filename) from local storage")
                    return true
                }
            }
        } catch {
            logger.error("Failed to search local directory: \(error.localizedDescription)")
            return false
        }

        // Nothing to delete is the outcome asked for, like a mirror's 404.
        logger.info("Media file already absent from local storage: \(sha256.prefix(8))")
        return true
    }

    /// Check if a URL is localhost
    private func isLocalhost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
    }

    // MARK: - Mirror Status Checking

    /// Check which configured mirrors have a specific blob
    /// - Parameter sha256: The SHA256 hash of the blob to check
    /// - Returns: Dictionary mapping mirror URL to availability status
    func checkMirrorStatus(sha256: String) async -> [String: Bool] {
        let presence = await checkMirrorPresence(sha256: sha256)
        return presence.mapValues { $0 == .present }
    }

    /// Asks every configured Blossom server whether it holds `sha256`.
    /// Unlike `checkMirrorStatus`, a server that could not be reached is
    /// reported as `.unreachable`, not as "does not have it".
    func checkMirrorPresence(sha256: String) async -> [String: BlobPresence] {
        let mirrors = await MainActor.run { configService.config.activeBlossomMirrors }
        guard !mirrors.isEmpty else { return [:] }

        return await withTaskGroup(of: (String, BlobPresence).self) { group in
            for mirror in mirrors {
                group.addTask {
                    (mirror, await self.checkBlobExists(mirror: mirror, sha256: sha256))
                }
            }
            var results: [String: BlobPresence] = [:]
            for await (mirror, presence) in group {
                results[mirror] = presence
            }
            return results
        }
    }

    /// Check if a specific blob exists on a mirror server.
    /// A 2xx alone is not enough: some servers answer 200 with an HTML page
    /// for any path, which used to read as "Available" for every file.
    private func checkBlobExists(mirror: String, sha256: String) async -> BlobPresence {
        guard var mirrorURL = URL(string: mirror) else { return .unreachable }

        // Ensure HTTPS for remote servers
        if mirrorURL.scheme == "http" && !isLocalhost(mirrorURL) {
            var components = URLComponents(url: mirrorURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secureURL = components?.url {
                mirrorURL = secureURL
            }
        }

        let blobURL = mirrorURL.appendingPathComponent(sha256)
        // Not HEAD: after a delete, blossom.band and blossom.nostr.build keep
        // answering HEAD with the old size, while a GET redirects to a
        // "404" placeholder image served as 200. A GET shows where the blob
        // really ends up; only its headers are read, never the body.
        var request = URLRequest(url: blobURL)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 10

        do {
            let session = isLocalhost(mirrorURL) ? localhostSession : remoteSession
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return Self.presence(statusCode: http.statusCode,
                                 contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                 contentLength: http.value(forHTTPHeaderField: "Content-Length"),
                                 sha256: sha256,
                                 finalURL: http.url)
        } catch {
            logger.debug("checkBlobExists: \(mirror)/\(sha256.prefix(8)) error: \(error.localizedDescription)")
            return .unreachable
        }
    }

    /// The decision behind `checkBlobExists`, split out so it can be tested
    /// without a server.
    /// `finalURL` is where redirects ended. A blob's own location names its
    /// hash; a redirect that lands anywhere else is a placeholder.
    static func presence(statusCode: Int, contentType: String?, contentLength: String?,
                         sha256: String? = nil, finalURL: URL? = nil) -> BlobPresence {
        switch statusCode {
        case 200...299:
            if let type = contentType?.lowercased(), type.hasPrefix("text/html") { return .absent }
            if let sha256, let finalURL,
               !finalURL.absoluteString.lowercased().contains(sha256.lowercased()) { return .absent }
            if let length = contentLength.flatMap({ Int64($0) }), length == 0 { return .absent }
            return .present
        case 400...499:
            return .absent
        default:
            return .unreachable
        }
    }
}

/// Whether one Blossom server holds a blob.
enum BlobPresence: Sendable, Equatable {
    case present
    case absent
    /// The server did not answer (offline, timeout, 5xx), so we do not know.
    case unreachable
}

/// Helper class conforming to NSObject and URLSessionTaskDelegate to report body upload progress.
class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progressHandler: (Double) -> Void
    
    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        progressHandler(progress)
    }
}

/// Pre-signed BUD-02 upload authorisations, by signing account and blob hash.
///
/// Shared rather than held per `BlossomService` on purpose: the views build a
/// fresh service on every access (`ComposeView.blossomService` is a computed
/// property), so an instance-held cache would be thrown away between
/// pre-signing an attachment's authorisation and uploading the blob.
///
/// An authorisation is scoped to `t: upload` and `x: <sha256>` and nothing
/// else — not to a request, not to a server — so one signature is good for
/// every request that blob needs until it expires, including a retry of a
/// failed post.
actor UploadAuthCache {
    static let shared = UploadAuthCache()

    private struct Prepared {
        let base64: String
        let expiresAt: Int64
    }
    private var prepared: [String: Prepared] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    /// The authorisation for `signer` and `sha256`, signing one through `sign`
    /// if there is none to reuse. Callers that arrive while a signature is
    /// out — the upload catching up with its own pre-sign — wait for that one
    /// answer instead of putting a second request to the signer.
    func authorisation(signer: String, sha256: String,
                       sign: @escaping @Sendable () async -> (base64: String, expiresAt: Int64)?) async -> String? {
        let key = signer + ":" + sha256
        let now = Int64(Date().timeIntervalSince1970)
        if let entry = prepared[key] {
            // Keep a wide margin: an authorisation that expires mid-upload is
            // worse than one more signature here, and a large video can take
            // minutes to reach every mirror.
            if entry.expiresAt - now > 600 { return entry.base64 }
            prepared[key] = nil
        }
        if let outstanding = inFlight[key] { return await outstanding.value }

        let task = Task<String?, Never> { [weak self] in
            guard let signed = await sign() else { return nil }
            await self?.store(key: key, base64: signed.base64, expiresAt: signed.expiresAt)
            return signed.base64
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    private func store(key: String, base64: String, expiresAt: Int64) {
        prepared[key] = Prepared(base64: base64, expiresAt: expiresAt)
        prune()
    }

    /// Nothing clears this cache on an account switch and nothing needs to —
    /// the signing pubkey is part of the key, so an entry can only ever be
    /// handed back to the account that signed it. This just keeps the map from
    /// growing for the life of the process.
    private func prune() {
        let now = Int64(Date().timeIntervalSince1970)
        prepared = prepared.filter { $0.value.expiresAt > now }
        guard prepared.count > Self.maxPrepared else { return }
        let keep = prepared.sorted { $0.value.expiresAt > $1.value.expiresAt }
            .prefix(Self.maxPrepared)
        prepared = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    private static let maxPrepared = 32
}
