import Foundation
import CryptoKit
import os.log

extension BlossomService {
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
    func uploadToLocalWithRecovery(source: UploadSource, sha256: String, contentType: String, authBase64: String? = nil) async -> URL? {
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

    func saveToLocalRelay(source: UploadSource, sha256: String, contentType: String, mirrorToExternal: Bool, progress: ((Double) -> Void)? = nil) async -> Bool {
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
}
