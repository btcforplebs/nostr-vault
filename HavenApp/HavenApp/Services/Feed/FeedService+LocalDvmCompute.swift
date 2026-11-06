import Foundation

extension FeedService {
    /// The relay call behind each local DVM feed, run off the main thread.
    /// Catch Up hands the relay the active account's follow list, which it
    /// does not know on its own when several accounts share it. nil when
    /// Catch Up has no follow list yet: it is loaded first, and Catch Up
    /// asked for again once it lands.
    func dvmCompute(for feed: LocalDvmFeed) -> (() -> UnsafeMutablePointer<CChar>?)? {
        switch feed {
        case .popular:
            return { ComputePopularNotesC() }
        case .underrated:
            return { ComputeUnderratedNotesC() }
        case .catchUp:
            var follows = followedPubkeys
            if follows.isEmpty {
                // This account's backup: the shared service may hold another
                // account's, loaded by Following Backup.
                follows = FollowingBackupService.shared.latestPubkeys(forAccountKey: currentSnapshotKey())
            }
            if follows.isEmpty && !hasAttemptedContactLoad {
                if !isLoadingContacts {
                    loadContactList { [weak self] in
                        guard let self, self.feedMode == .catchUp else { return }
                        self.loadLocalDvmFeed()
                    }
                }
                return nil
            }
            let json = LocalDvmFeed.followsJSON(follows)
            return { json.withCString { ComputeCatchUpNotesC(UnsafeMutablePointer(mutating: $0)) } }
        }
    }
}
