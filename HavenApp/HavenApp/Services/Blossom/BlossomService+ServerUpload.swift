import Foundation
import CryptoKit
import os.log

extension BlossomService {
    /// Upload media to a specific Blossom server with retry logic
    /// Uses Blossom HTTP Auth (kind 24242, per BUD-01 spec)
    /// `authBase64` is a pre-signed BUD-02 authorisation from makeUploadAuth,
    /// reused across the preflight, the retries and every mirror for one blob.
    /// Passing nil makes this sign its own, for callers that upload a single
    /// blob to a single server.
    func uploadToServer(source: UploadSource, url: String, sha256: String, contentType: String, useLocalhostSession: Bool, authBase64: String? = nil, progress: ((Double) -> Void)? = nil) async -> URL? {
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
    func preflightCheck(url: String, sha256: String, contentLength: Int, contentType: String, useLocalhostSession: Bool, authBase64: String? = nil) async -> Bool {
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
}
