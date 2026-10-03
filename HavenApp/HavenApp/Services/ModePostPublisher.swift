import Foundation
import CryptoKit

/// Uploads and publishing shared by the diVine, article and recipe composers.
///
/// These are addressable events (kinds 34236 and 30023). The device's relay
/// stores them through its replace path, which does not blast them onward the
/// way it does notes, so they are sent to the outside relays directly here.
@MainActor
enum ModePostPublisher {
    struct UploadedBlob {
        let url: URL
        let sha256: String
        let byteCount: Int
    }

    enum PublishError: LocalizedError {
        case upload(String)
        case signing

        var errorDescription: String? {
            switch self {
            case .upload(let message): return message
            case .signing: return "Couldn't sign the post. Check your key or remote signer in Settings."
            }
        }
    }

    /// Uploads a file to this device's relay and the outside Blossom servers.
    /// A post that points at media only this phone holds is unreadable to
    /// everyone else, so anything short of an outside URL is an error.
    static func upload(fileURL: URL, mimeType: String, configService: ConfigService, nostrService: NostrService,
                       progress: ((Double) -> Void)? = nil) async throws -> UploadedBlob {
        guard let sha256 = ComposeView.streamingSHA256(of: fileURL) else {
            throw PublishError.upload("Couldn't read the file to upload.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int ?? 0
        let blossom = BlossomService(configService: configService, nostrService: nostrService)
        let outcome = await blossom.uploadForPost(fileURL: fileURL, sha256: sha256, contentType: mimeType, progress: progress)
        return UploadedBlob(url: try hostedURL(outcome), sha256: sha256, byteCount: size)
    }

    static func upload(data: Data, mimeType: String, configService: ConfigService, nostrService: NostrService) async throws -> UploadedBlob {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let blossom = BlossomService(configService: configService, nostrService: nostrService)
        let outcome = await blossom.uploadForPost(data: data, sha256: sha256, contentType: mimeType)
        return UploadedBlob(url: try hostedURL(outcome), sha256: sha256, byteCount: data.count)
    }

    private static func hostedURL(_ outcome: BlossomService.PostUploadOutcome) throws -> URL {
        switch outcome {
        case .hosted(let url):
            return url
        case .savedOnDevice:
            throw PublishError.upload("No outside media server took the upload. Try again when one is reachable.")
        case .noOutsideServer:
            throw PublishError.upload(MediaUploadOutcomeMessage.noOutsideServer)
        case .notSavedOnDevice:
            throw PublishError.upload(MediaUploadOutcomeMessage.notSavedOnDevice)
        }
    }

    /// Signs and sends an event to this device's relay, the configured outside
    /// relays and `extraRelays`. `onRelayResult` reports each outside relay.
    @discardableResult
    static func publish(kind: Int, content: String, tags: [[String]], extraRelays: [String] = [],
                        nostrService: NostrService,
                        onRelayResult: ((String, Bool, String) -> Void)? = nil) async throws -> NostrEvent {
        guard let event = await nostrService.signEventAsync(kind: kind, content: content, tags: tags) else {
            throw PublishError.signing
        }
        nostrService.postEvent(event)
        let eventDict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.created_at,
            "kind": event.kind,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig
        ]
        nostrService.broadcastRawEvent(eventDict, extraRelays: extraRelays, onRelayResult: onRelayResult)
        return event
    }
}
