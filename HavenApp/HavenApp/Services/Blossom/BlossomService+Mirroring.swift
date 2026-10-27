import Foundation
import CryptoKit
import os.log

extension BlossomService {
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

    func uploadAndMirror(source: UploadSource, sha256: String, contentType: String, skipOutsideServers: Bool, progress: ((Double) -> Void)?) async -> PostUploadOutcome {
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

        #if os(iOS)
        // A copy for the owner's home vault (a kiosk phone, or the Mac set by
        // mesh npub). With no server on this phone, the vault passes it on to
        // the owner's public server from their 10063, which the note links.
        let signer = await MainActor.run { nostrService.activeHexPubkey }
        let forwardTo = await MainActor.run {
            HomeVaultLogic.forwardServer(phoneMirrors: mirrors, ownerServerList: nostrService.serverLists[signer] ?? [])
        }
        let size = source.byteCount
        let toHomeVault = await MainActor.run {
            HomeVaultSender.shared.enqueue(blobSha256: sha256, contentType: contentType, signer: signer, byteCount: size, forwardTo: forwardTo)
        }
        #else
        let toHomeVault = false
        let forwardTo: String? = nil
        #endif

        guard !mirrors.isEmpty else {
            if let forwardTo, let link = await kioskOnlyLink(toHomeVault: toHomeVault, mirrors: [forwardTo], sha256: sha256, contentType: contentType, vaultForwards: true) {
                appLog("post upload ok — on the home vault, which passes it on to \(forwardTo)")
                return .hosted(link)
            }
            // A vault was asked to pass it on and did not take it: the fix is
            // the vault (is the app open?), not adding a server (2026-10-21).
            if let forwardTo {
                appLog("post upload stopped at stage 2 of 2 — saved on this device; the home vault did not take it to pass on to \(forwardTo)", level: "ERROR")
                return .vaultDidNotTake
            }
            appLog("post upload stopped at stage 2 of 2 — saved on this device, but no outside Blossom server is configured" + (toHomeVault ? " and the home vault did not confirm it" : ""), level: "ERROR")
            return .noOutsideServer
        }

        if skipOutsideServers {
            appLog("saved \(sha256.prefix(8)) on this device only — an earlier attachment found every outside server down")
            if let link = await kioskOnlyLink(toHomeVault: toHomeVault, mirrors: mirrors, sha256: sha256, contentType: contentType) {
                return .hosted(link)
            }
            return .savedOnDevice(unreachable: mirrors)
        }

        // Step 3: Upload to every outside server at once and post as soon as
        // ONE has it. The others keep uploading in the background; a server
        // that fails or hangs can't hold the post.
        var hostedURL = await firstHostingMirror(source: source, sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: progress)

        // A sleeping mirror host (e.g. the Mac relay over LAN/Tailscale) is often
        // woken *by* the first pass's connection attempts (wake-on-network) but
        // isn't up fast enough to serve it. Wait and retry the whole pass once
        // before handing the post to the queue.
        if hostedURL == nil {
            logger.warning("All Blossom mirrors failed — retrying once in 10s in case a sleeping host is still waking")
            appLog("first mirror pass failed for all of \(mirrors) — retrying once in 10s", level: "WARN")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            hostedURL = await firstHostingMirror(source: source, sha256: sha256, contentType: contentType, mirrors: mirrors, authBase64: auth, progress: progress)
        }

        if let externalURL = hostedURL {
            logger.info("Using external Blossom mirror: \(externalURL.absoluteString)")
            appLog("post upload ok — mirrored to \(externalURL.absoluteString)")
            return .hosted(externalURL)
        }

        if let link = await kioskOnlyLink(toHomeVault: toHomeVault, mirrors: mirrors, sha256: sha256, contentType: contentType) {
            return .hosted(link)
        }
        appLog("post upload paused at stage 2 of 2 — saved on this device, no outside server accepted it after two passes; the post will wait for one", level: "WARN")
        return .savedOnDevice(unreachable: mirrors)
    }

    /// The blob is on this phone and on its way to the home vault, but no public
    /// server has it yet. The note goes out now (Logen's call) with the link the
    /// first public server will serve it at, and the public upload keeps being
    /// retried; NIP-F1 readers find the kiosk copy by hash meanwhile. nil: hold
    /// the note as before.
    /// `vaultForwards`: the vault was asked to pass it on, so this phone's own
    /// public upload is only the fallback and waits longer.
    private func kioskOnlyLink(toHomeVault: Bool, mirrors: [String], sha256: String, contentType: String, vaultForwards: Bool = false) async -> URL? {
        #if os(iOS)
        guard toHomeVault,
              let server = HomeVaultLogic.linkServer(mirrors: mirrors, sha256: sha256, contentType: contentType),
              let link = HomeVaultLogic.publicBlobURL(server: server, sha256: sha256, contentType: contentType) else { return nil }
        // Only once the vault really holds it: queued is not enough (Tron, #473).
        guard await HomeVaultSender.shared.ensureOnVault(sha256: sha256) else {
            appLog("\(sha256.prefix(8)) not confirmed on the home vault — the post waits for a public server as before")
            return nil
        }
        let signer = await MainActor.run { nostrService.activeHexPubkey }
        let queued = await MainActor.run {
            HomeVaultSender.shared.enqueue(mirrorSha256: sha256, contentType: contentType, signer: signer, server: server,
                                           firstTryAfter: vaultForwards ? HomeVaultLogic.forwardFallbackDelay : 60)
        }
        guard queued else { return nil }
        appLog("\(sha256.prefix(8)) is on the home vault; the note links \(link.absoluteString) and the public upload keeps retrying")
        return link
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// One more public upload of a blob this phone already holds (the
    /// kiosk-only case), to `server`, the one the note names. True once that
    /// server has it; another server alone leaves the link dead.
    func mirrorFromLocal(sha256: String, contentType: String, server: String?) async -> Bool {
        guard let server else { return false }
        // The vault may have passed it on already (photos through the Mac):
        // never send the same photo up twice over mobile data.
        if await checkPresence(mirror: server, sha256: sha256) == .present {
            appLog("kiosk-only \(sha256.prefix(8)) is already on \(server)")
            return true
        }
        guard let file = await HomeVaultTransport.localBlobFile(sha256: sha256) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        let auth = await makeUploadAuth(sha256: sha256)
        let urls = await mirrorUploadPass(source: .file(file), sha256: sha256, contentType: contentType, mirrors: [server], authBase64: auth, progress: nil)
        // One server asked, so any result is that server taking it. The URL it
        // returns is its descriptor's, which may name a CDN host (Tron, #473).
        let done = !urls.isEmpty
        if done { appLog("kiosk-only \(sha256.prefix(8)) is now on \(server), where the note links it") }
        return done
    }
    #endif

    /// One concurrent BUD-02 upload pass over all configured mirrors.
    /// Returns the URLs of every mirror that accepted the blob, in the order
    /// the servers are configured. Waits for all of them: for pushes that
    /// report how many servers took a blob, not for posting.
    func mirrorUploadPass(source: UploadSource, sha256: String, contentType: String, mirrors: [String], authBase64: String?, progress: ((Double) -> Void)?) async -> [URL] {
        logger.debug("Attempting to mirror to: \(mirrors.description)")
        return await withTaskGroup(of: (Int, URL?).self) { group in
            for (index, mirrorURL) in mirrors.enumerated() {
                group.addTask {
                    (index, await self.uploadToMirror(source: source, sha256: sha256, contentType: contentType, mirror: mirrorURL, authBase64: authBase64, progress: index == 0 ? progress : nil))
                }
            }
            var successfulMirrors: [(index: Int, url: URL)] = []
            for await (index, result) in group {
                if let url = result { successfulMirrors.append((index, url)) }
            }
            return successfulMirrors.sorted { $0.index < $1.index }.map(\.url)
        }
    }

    /// Uploads to every mirror at once and returns the link from the first
    /// that accepts the blob — the post doesn't wait for the rest, which
    /// finish in the background. nil once every mirror has failed.
    func firstHostingMirror(source: UploadSource, sha256: String, contentType: String, mirrors: [String], authBase64: String?, progress: ((Double) -> Void)?) async -> URL? {
        // The stragglers outlive this call, so they read their own link to a
        // file source: the caller deletes its temp file once the post is out.
        var raceSource = source
        var raceFile: URL?
        if case .file(let fileURL) = source {
            let link = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-race-\(UUID().uuidString)")
            if (try? FileManager.default.linkItem(at: fileURL, to: link)) != nil
                || (try? FileManager.default.copyItem(at: fileURL, to: link)) != nil {
                raceSource = .file(link)
                raceFile = link
            }
        }
        let source = raceSource
        let jobs: [@Sendable () async -> URL?] = mirrors.enumerated().map { index, mirrorURL in
            { await self.uploadToMirror(source: source, sha256: sha256, contentType: contentType, mirror: mirrorURL, authBase64: authBase64, progress: index == 0 ? progress : nil) }
        }
        return await FirstAnswer.first(jobs, onLate: { index, url in
            if let url {
                self.appLog("background mirror ok — \(mirrors[index]) also has \(sha256.prefix(8)): \(url.absoluteString)")
            }
        }, onAllDone: {
            if let raceFile { try? FileManager.default.removeItem(at: raceFile) }
        })
    }

    /// BUD-06 preflight, then the BUD-02 upload, to one mirror.
    private func uploadToMirror(source: UploadSource, sha256: String, contentType: String, mirror mirrorURL: String, authBase64: String?, progress: ((Double) -> Void)?) async -> URL? {
        let useLocalSession = URL(string: mirrorURL).map { isLocalhost($0) } ?? false
        // BUD-06: Preflight check — skip mirror if server rejects
        let accepted = await preflightCheck(
            url: mirrorURL, sha256: sha256,
            contentLength: source.byteCount, contentType: contentType,
            useLocalhostSession: useLocalSession, authBase64: authBase64
        )
        guard accepted else {
            logger.info("BUD-06: Skipping mirror \(mirrorURL) — preflight rejected")
            return nil
        }
        let result = await uploadToServer(source: source, url: mirrorURL, sha256: sha256, contentType: contentType, useLocalhostSession: useLocalSession, authBase64: authBase64, progress: progress)
        if let result {
            logger.info("Mirror upload succeeded for \(mirrorURL): \(result.absoluteString)")
        } else {
            logger.warning("Mirror upload failed for \(mirrorURL)")
        }
        return result
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
}

// MARK: - Copy a stored file to servers

/// How sending one file to one server went, in words a person can act on.
/// `stopped` is a send cut short by Stop: the file is still waiting.
enum BlobCopyOutcome: Equatable {
    case copied
    case failed(String)
    case stopped
}

extension BlossomService {
    /// Sessions for copying stored files. Unlike `remoteSession` they do not
    /// wait for connectivity: that wait lasted up to 15 minutes a try, which
    /// is part of how the Media servers page sat on "Copied 0 of 11" with
    /// nothing to say. There is no cap on a whole upload, so a big video on a
    /// slow line keeps going while bytes move; 150 s with nothing moving is a
    /// stall. That limit also covers the wait after the last byte, while a
    /// server works on a big file before it answers.
    private static let copySession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    private static let copyLocalDelegate = LocalhostTrustDelegate()
    private static let copyLocalSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 150
        return URLSession(configuration: config, delegate: copyLocalDelegate, delegateQueue: nil)
    }()

    /// One upload authorisation for several files: an `x` tag per hash.
    ///
    /// Signing one per file is what held the copy at "0 of 11" with a remote
    /// signer: each file could wait 90 s for the signer, twice, before failing
    /// without a word. BUD-11 lets an authorisation carry several `x` tags; on
    /// `PUT /upload` the server needs one that matches `X-SHA-256`. A server
    /// that refuses it gets a single-file signature instead, see
    /// `copyStoredBlob`. No time limit of our own: the signer bridge has one,
    /// and an approval that comes late must still count.
    func makeBatchUploadAuth(hashes: [String]) async -> String? {
        guard !hashes.isEmpty else { return nil }
        let expiration = Int64(Date().timeIntervalSince1970) + 3 * 3600
        let tags = [["t", "upload"]] + hashes.map { ["x", $0] } + [["expiration", String(expiration)]]
        let content = hashes.count == 1 ? "Upload blob \(hashes[0].prefix(8))..." : "Upload \(hashes.count) blobs"
        appLog("copy: asking the signer for one upload authorisation covering \(hashes.count) file(s)")
        let event = await nostrService.signEventAsync(kind: 24242, content: content, tags: tags)
        guard let event, let json = try? JSONEncoder().encode(event) else {
            appLog("copy: the signer gave no upload authorisation", level: "WARN")
            return nil
        }
        return json.base64EncodedString()
    }

    /// Why signing failed, in the words for the signer this account uses.
    func signerProblem() async -> String {
        let mode = await MainActor.run { ConfigService.shared.config.activeSigningMode() }
        return mode == "nip46"
            ? "Your signer didn't answer. Open it, approve the request if it asks, then tap Retry."
            : "Couldn't sign with your key. If it's locked with a password, unlock it, then tap Retry."
    }

    /// Sends a file stored on this device to each of `servers`, streaming it
    /// from disk, and says what happened at each one. `batchAuth` is a shared
    /// authorisation from `makeBatchUploadAuth`; without one, or when a server
    /// turns it down, the file is signed on its own, once for all servers.
    /// `run` remembers across files which servers refuse the key outright, so
    /// they are not sent to the signer again. Every outcome is written to the
    /// app log.
    func copyStoredBlob(sha256: String, fileURL: URL, to servers: [String], batchAuth: String? = nil,
                        run: BlobCopyRun = BlobCopyRun()) async -> [String: BlobCopyOutcome] {
        let tag = String(sha256.prefix(8))
        guard !servers.isEmpty else { return [:] }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > 0 else {
            appLog("copy \(tag): the file is no longer on this device", level: "WARN")
            return Dictionary(uniqueKeysWithValues: servers.map { ($0, .failed("This file is no longer on this phone.")) })
        }
        let contentType = Self.sniffContentType(fileURL)
        appLog("copy \(tag) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)), \(contentType)) to \(servers.joined(separator: ", "))")

        var results: [String: BlobCopyOutcome] = [:]
        var viaBatch: [String] = []
        var viaSingle: [String] = []
        for server in servers {
            if let reason = await run.refusal(server) {
                results[server] = .failed(reason)
            } else if batchAuth != nil, !(await run.wantsSingle(server)) {
                viaBatch.append(server)
            } else {
                viaSingle.append(server)
            }
        }

        // The file's own signature, asked for at most once whatever the
        // number of servers: makeUploadAuth caches it per hash.
        var single: String?
        var singleAsked = false
        func singleAuth() async -> String? {
            if !singleAsked { singleAsked = true; single = await makeUploadAuth(sha256: sha256) }
            return single
        }
        func send(_ targets: [String], auth: String) async -> [String: CopyAttempt] {
            await withTaskGroup(of: (String, CopyAttempt).self) { group in
                for server in targets {
                    group.addTask { (server, await self.putWithRetry(fileURL: fileURL, size: size, sha256: sha256, contentType: contentType, server: server, auth: auth)) }
                }
                var attempts: [String: CopyAttempt] = [:]
                for await (server, attempt) in group { attempts[server] = attempt }
                return attempts
            }
        }
        func signFailed(_ targets: [String]) async {
            let outcome: BlobCopyOutcome = Task.isCancelled ? .stopped : .failed(await signerProblem())
            if !Task.isCancelled { appLog("copy \(tag): could not sign the upload", level: "WARN") }
            for server in targets { results[server] = outcome }
        }

        if let batchAuth, !viaBatch.isEmpty {
            for (server, attempt) in await send(viaBatch, auth: batchAuth) {
                if attempt.authRefused, !Task.isCancelled {
                    // Maybe a server that wants exactly one hash per signature.
                    viaSingle.append(server)
                } else {
                    results[server] = attempt.outcome
                }
            }
        }
        if !viaSingle.isEmpty {
            if Task.isCancelled {
                for server in viaSingle { results[server] = .stopped }
            } else if let auth = await singleAuth() {
                for (server, attempt) in await send(viaSingle, auth: auth) {
                    results[server] = attempt.outcome
                    if attempt.authRefused, case .failed(let reason) = attempt.outcome {
                        // Maybe it refuses the key itself: not on its list,
                        // unpaid. Then no more signatures for it this run.
                        await run.noteRefusal(server, hash: sha256, status: attempt.status, reason: reason)
                    } else if batchAuth != nil, attempt.outcome == .copied {
                        await run.markWantsSingle(server)
                    }
                }
            } else {
                await signFailed(viaSingle)
            }
        }

        for (server, outcome) in results {
            switch outcome {
            case .copied: appLog("copy \(tag) to \(server): done")
            case .failed(let reason): appLog("copy \(tag) to \(server) failed: \(reason)", level: "WARN")
            case .stopped: appLog("copy \(tag) to \(server): stopped")
            }
        }
        return results
    }

    /// One PUT, and one more for the failures that tend to pass: a server
    /// error, a dropped connection, a stall.
    private func putWithRetry(fileURL: URL, size: Int, sha256: String, contentType: String, server: String, auth: String) async -> CopyAttempt {
        let attempt = await putStoredBlob(fileURL: fileURL, size: size, sha256: sha256, contentType: contentType, server: server, auth: auth)
        guard attempt.worthRetry, !Task.isCancelled else { return attempt }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return CopyAttempt(outcome: .stopped) }
        return await putStoredBlob(fileURL: fileURL, size: size, sha256: sha256, contentType: contentType, server: server, auth: auth)
    }

    /// One PUT's result, and whether the failure is the kind that passes.
    struct CopyAttempt {
        let outcome: BlobCopyOutcome
        var worthRetry = false
        var authRefused = false
        /// The HTTP status of a refusal, so the run can tell 401 from 403.
        var status: Int?
        static let copied = CopyAttempt(outcome: .copied)
        static func failed(_ reason: String, retry: Bool = false, authRefused: Bool = false, status: Int? = nil) -> CopyAttempt {
            CopyAttempt(outcome: .failed(reason), worthRetry: retry, authRefused: authRefused, status: status)
        }
    }

    private func putStoredBlob(fileURL: URL, size: Int, sha256: String, contentType: String, server: String, auth: String) async -> CopyAttempt {
        guard var serverURL = URL(string: server) else { return .failed("This server address isn't valid.") }
        let local = isLocalhost(serverURL)
        if serverURL.scheme == "http" && !local {
            var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            if let secure = components?.url { serverURL = secure }
        }
        var request = URLRequest(url: serverURL.appendingPathComponent("upload"))
        request.httpMethod = "PUT"
        request.setValue("Nostr \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue(sha256, forHTTPHeaderField: "X-SHA-256")
        do {
            let session = local ? Self.copyLocalSession : Self.copySession
            let (body, response) = try await session.upload(for: request, fromFile: fileURL)
            guard let http = response as? HTTPURLResponse else { return .failed("The server sent back nothing.", retry: true) }
            if (200...299).contains(http.statusCode) {
                // A website that answers every PUT with its home page has not
                // stored anything (see BlossomUploadReply).
                let isOnDevice = ["localhost", "127.0.0.1", "0.0.0.0"].contains(serverURL.host?.lowercased() ?? "")
                guard BlossomUploadReply.hostedURL(body: body, server: serverURL, sha256: sha256, onDeviceRelay: isOnDevice) != nil else {
                    return .failed("This address answered, but not as a Blossom media server. For nostr.build, use https://blossom.nostr.build.")
                }
                return .copied
            }
            let why = http.value(forHTTPHeaderField: "X-Reason")
                ?? String(data: body.prefix(200), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.copyFailure(status: http.statusCode, serverSays: why)
        } catch let error as URLError {
            return Self.copyFailure(error)
        } catch {
            return .failed(error.localizedDescription, retry: true)
        }
    }

    static func copyFailure(status: Int, serverSays: String?) -> CopyAttempt {
        let said = serverSays.flatMap { $0.isEmpty || $0.hasPrefix("<") ? nil : $0 }
        let suffix = said.map { " It said: \"\($0)\"." } ?? ""
        switch status {
        case 401, 403: return .failed("The server turned down your key (HTTP \(status))." + suffix, authRefused: true, status: status)
        case 402: return .failed("The server wants payment to store files (HTTP 402)." + suffix)
        case 409: return .failed("The server already has a different file under this name (HTTP 409)." + suffix)
        case 413: return .failed("Too big for this server (HTTP 413)." + suffix)
        case 415: return .failed("The server doesn't take this type of file (HTTP 415)." + suffix)
        // Shown only after the retry two seconds later was turned down too.
        case 429: return .failed("The server asked us to slow down (HTTP 429). Wait a minute, then tap Retry.", retry: true)
        case 500...599: return .failed("The server had a problem (HTTP \(status)). Try again later." + suffix, retry: true)
        default: return .failed("The server said no (HTTP \(status))." + suffix)
        }
    }

    static func copyFailure(_ error: URLError) -> CopyAttempt {
        switch error.code {
        case .cancelled: return CopyAttempt(outcome: .stopped)
        case .timedOut: return .failed("The server stopped answering.", retry: true)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .failed("This phone is offline.")
        case .cannotFindHost, .dnsLookupFailed: return .failed("Couldn't find the server's address.")
        case .cannotConnectToHost: return .failed("The server isn't answering.", retry: true)
        case .networkConnectionLost: return .failed("The connection dropped.", retry: true)
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return .failed("Couldn't make a secure connection to the server.")
        case .fileDoesNotExist, .noPermissionsToReadFile: return .failed("This file is no longer on this phone.")
        default: return .failed(error.localizedDescription, retry: true)
        }
    }

    /// The type to send, from the file's first bytes: the stored name has no
    /// extension, and "application/octet-stream" makes some servers serve a
    /// photo as a download.
    static func sniffContentType(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "application/octet-stream" }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 16)) ?? Data())
        func at(_ offset: Int, _ bytes: [UInt8]) -> Bool {
            head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if at(0, [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if at(0, [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if at(0, Array("GIF8".utf8)) { return "image/gif" }
        if at(0, Array("RIFF".utf8)) && at(8, Array("WEBP".utf8)) { return "image/webp" }
        if at(4, Array("ftyp".utf8)) {
            if at(8, Array("qt  ".utf8)) { return "video/quicktime" }
            if at(8, Array("heic".utf8)) || at(8, Array("heix".utf8)) || at(8, Array("mif1".utf8)) { return "image/heic" }
            if at(8, Array("avif".utf8)) { return "image/avif" }
            if at(8, Array("M4A ".utf8)) { return "audio/mp4" }
            return "video/mp4"
        }
        if at(0, [0x1A, 0x45, 0xDF, 0xA3]) { return "video/webm" }
        if at(0, Array("ID3".utf8)) || at(0, [0xFF, 0xFB]) { return "audio/mpeg" }
        if at(0, Array("%PDF".utf8)) { return "application/pdf" }
        return "application/octet-stream"
    }
}
