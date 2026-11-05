import Foundation

/// Import media runs once by itself when the first Moving in finishes, so a
/// new vault holds the owner's media without anyone finding the button. Once
/// per device, never on a plain start, and not at all if Import media
/// already ran here. Android twin: `MediaImportAfterMovingInRule`.
struct MediaImportAfterMovingInRule {
    var started: () -> Bool
    var markStarted: () -> Void
    var mediaImportedAt: () -> Date?
    /// Starts Import media; false when one is already running (that one counts).
    var runImport: () -> Bool

    /// A Moving in completed and the relay serves again. True when this started Import media.
    @discardableResult
    func movingInDone() -> Bool {
        guard !started(), mediaImportedAt() == nil else { return false }
        let ran = runImport()
        markStarted()
        return ran
    }
}

/// How Import media puts a file into this device's own vault. A vault with an
/// account key (or a signer) uploads over HTTP with a signed kind 24242, as it
/// always did. A keyless vault (npub only) cannot sign that, so it imported
/// nothing (0/250 server blobs, 0/71 note media on a 12 mini); it hands the
/// file to the vault in-process instead (`ImportOwnerBlobC`), which is no HTTP
/// route, so nobody else gains a way to upload, and no signer is asked.
enum OwnVaultUpload: Equatable {
    case signedUpload
    case inProcess

    static func route(keyless: Bool) -> OwnVaultUpload { keyless ? .inProcess : .signedUpload }
}
