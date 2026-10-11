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
    func mirrorUploadPass(source: UploadSource, sha256: String, contentType: String, mirrors: [String], authBase64: String?, progress: ((Double) -> Void)?) async -> [URL] {
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
}
