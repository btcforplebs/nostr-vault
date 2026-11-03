import SwiftUI

/// A shared profile link (npub / nprofile, nostrvault.app/p/, njump): follow
/// or block that person. Neither list is written here: Follow is
/// `FeedService.followUser` (the guarded kind 3 path: fetch the newest list,
/// apply only this change, ListShrinkRule / ContactManager.mayPublish, roll
/// back on refusal) and Block is `ConfigService.blockProfile` (the kind 10000
/// merged path every Block button uses). Tron review (list safety). Twin:
/// ProfileShareHandler.kt.
struct ProfileShareHandler: SharePortalHandler {
    let action = NVShareAction.profile

    func review(_ intent: NVShareIntent, close: @escaping () -> Void) -> AnyView {
        AnyView(ProfileShareReviewView(intent: intent, close: close))
    }
}

extension ProfileShareHandler {
    /// The people the share names, hex, first one first.
    static func people(in intent: NVShareIntent) -> [String] {
        ProfileShareTarget.pubkeys(url: intent.source.url, text: intent.source.text, selection: intent.source.selection)
    }

    enum FollowOutcome: Equatable {
        case followed
        case alreadyFollowing
        /// Queued by FeedService until the follow list has loaded: never
        /// published against a list it hasn't seen.
        case queued
        case failed(String)
    }

    @MainActor
    static func follow(_ hex: String) -> FollowOutcome {
        let name = displayName(hex)
        let result = FeedService.shared.followUser(hex) {
            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                           message: ContactManager.publishFailedMessage(
                                               follow: true, readOnly: FeedService.activeAccountIsReadOnly,
                                               noRelayList: FeedService.activeAccountHasNoRelayList),
                                           tone: .error)
        }
        switch result {
        case .success:
            ActionToastManager.shared.show(icon: "person.badge.plus", message: "Following \(name)")
            return .followed
        case .failure(.alreadyFollowing): return .alreadyFollowing
        case .failure(.contactsNotLoaded), .failure(.listUnavailable):
            ActionToastManager.shared.show(icon: "clock", message: "Will follow \(name) once your follow list loads")
            return .queued
        case .failure(.readOnly):
            return .failed(ContactManager.publishFailedMessage(follow: true, readOnly: true))
        case .failure(.cannotUnfollowSelf):
            return .failed("That's you.")
        }
    }

    /// The active account's block (mute list), as every Block button does it.
    @MainActor
    static func block(_ hex: String) -> Bool {
        guard let data = Bech32.hexToData(hex), let npub = Bech32.encode(hrp: "npub", data: data) else { return false }
        ConfigService.shared.blockProfile(npub)
        ActionToastManager.shared.show(icon: "hand.raised.fill", message: "Blocked \(displayName(hex))")
        return true
    }

    @MainActor
    static func isBlocked(_ hex: String) -> Bool {
        guard let data = Bech32.hexToData(hex), let npub = Bech32.encode(hrp: "npub", data: data) else { return false }
        let config = ConfigService.shared.config
        let active = PostingAccount.resolve(active: config.activeAccountNpub, owner: config.ownerNpub)
        return (config.blockedNpubsPerAccount[active] ?? []).contains(npub)
    }

    @MainActor
    static func displayName(_ hex: String) -> String {
        if let name = NostrService.shared.profiles[hex]?.bestName, !name.isEmpty { return name }
        let npub = Bech32.hexToData(hex).flatMap { Bech32.encode(hrp: "npub", data: $0) } ?? hex
        return String(npub.prefix(16)) + "…"
    }
}
