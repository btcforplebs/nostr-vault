import Foundation

/// When the composer may take a photo it uploaded back off the outside
/// servers (the photo was removed, or the note thrown away), so a delete
/// never removes a blob some other note shows. Same rule as Android
/// PR #1511 (Tron).
///
/// The location strip leaves a photo with no location data byte for byte as
/// it was, so picking a photo that is already in an earlier note gives the
/// same hash. Deleting it would take the image out of that note too.
enum UploadDeleteRule {
    /// What the pre-upload check found for one blob: the servers asked,
    /// recorded only when every one of them clearly said it did not have it.
    struct FreshUpload: Equatable {
        /// The servers asked. A later delete goes to these and no others.
        var servers: [String]
        /// The account that signed the upload; only it may delete.
        var signer: String?
    }

    /// Whether the blob was new to every server asked. One status per server;
    /// nil is no answer (timeout, network error). Anything but a 404 (a 2xx,
    /// a redirect, a server error, no answer) counts as already there, and so
    /// does asking nobody.
    static func isFresh(statuses: [Int?]) -> Bool {
        !statuses.isEmpty && statuses.allSatisfy { $0 == 404 }
    }

    /// The servers a delete for this blob may go to, or nil for no delete.
    /// - `fresh`: what the pre-upload check recorded for this hash (nil when
    ///   the blob was already out there, or the check could not tell).
    /// - `otherHashes`: the hashes of the photos still in the note; one with
    ///   the same hash still shows this blob.
    /// - `postTapped`: Post was tapped in this composer. From then on nothing
    ///   is deleted, even after a failed send: the photo may be in a queued or
    ///   pending note with its link at the end.
    /// - `activeHex`: the account a delete would be signed by.
    /// - `anyUnfinished`: a photo still in the note is waiting or uploading.
    ///   Its hash may not be known yet, and a copy of this photo checking the
    ///   servers mid-delete would see it as already there and link to a blob
    ///   about to go (Tron, PR #1514).
    static func deleteTargets(sha256: String, fresh: FreshUpload?, otherHashes: [String?],
                              postTapped: Bool, activeHex: String,
                              anyUnfinished: Bool = false) -> [String]? {
        guard !postTapped, !anyUnfinished, let fresh, !fresh.servers.isEmpty else { return nil }
        guard !otherHashes.contains(sha256) else { return nil }
        // Another account asking would tie the two together at the server.
        guard let signer = fresh.signer, signer == activeHex else { return nil }
        return fresh.servers
    }
}
