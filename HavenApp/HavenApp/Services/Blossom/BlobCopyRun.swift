import Foundation

/// What one copy run has learned about each server, so a server that turns
/// the key down is asked once, not once a file with a new signature each time.
///
/// Only a refusal of the key counts: a 401, or a 403 for two different files.
/// One 403 can be about that file alone (its type, its content), and marking
/// the server for it would fail every later file with that file's reason.
actor BlobCopyRun {
    private var refused: [String: String] = [:]
    private var forbidden: [String: Set<String>] = [:]
    private var singleOnly: Set<String> = []

    /// The reason a server gave when it refused the key for this run.
    func refusal(_ server: String) -> String? { refused[server] }

    /// A server turned down a one-file signature for `hash`.
    func noteRefusal(_ server: String, hash: String, status: Int?, reason: String) {
        if status == 403 {
            forbidden[server, default: []].insert(hash)
            guard forbidden[server, default: []].count >= 2 else { return }
        }
        refused[server] = reason
    }

    /// A server that took a one-file signature after turning down the batch one.
    func wantsSingle(_ server: String) -> Bool { singleOnly.contains(server) }
    func markWantsSingle(_ server: String) { singleOnly.insert(server) }
}
