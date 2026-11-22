import Foundation

/// What a media server list (kind 10063) publish did, for the one status line
/// under Settings › Media Servers' Save bar. Every refusal used to be a DEBUG
/// print, so Save could publish nothing and say nothing (dashboard parity
/// report gap C, 2026-11-22). Web shows "Published to X of Y relays" or the
/// reason (`MediaServersPage.jsx`); Android shows a banner
/// (`BlossomSettingsScreen.kt`).
enum ServerListPublishOutcome: Equatable {
    /// A new list was signed and sent.
    case published
    /// The newest list already held exactly these servers: nothing to send.
    case unchanged
    /// Too few relays answered to know the newest list, so nothing was sent
    /// rather than overwrite a list this phone hasn't seen.
    case listNotKnown(answered: Int, asked: Int)
    /// The account has no relay list of its own to publish to.
    case noRelayList
    /// The result would name no public (https, outside the home network)
    /// server, so nobody outside could load a photo from it.
    case noPublicServer
    /// The signer didn't sign (a bunker that didn't answer, or refused).
    case signFailed

    var message: String {
        switch self {
        case .published:
            return "Saved and published your media server list."
        case .unchanged:
            return "Saved. Your published media server list already has these servers."
        case .listNotKnown(let answered, let asked):
            return "Saved on this device, but not published: only \(answered) of \(asked) relays answered, so your current list couldn't be read. Nothing was changed on the relays."
        case .noRelayList:
            return "Saved on this device, but not published: your account has no relay list to publish it to. Add relays in Settings › Relays."
        case .noPublicServer:
            return "Not published: keep at least one public server, or photos have nowhere to go."
        case .signFailed:
            return "Saved on this device, but not published: your signer didn't sign the list."
        }
    }

    /// A refusal: the list on the relays is unchanged.
    var isRefusal: Bool {
        switch self {
        case .published, .unchanged: return false
        default: return true
        }
    }

    /// Worth a "Try again": the reason can pass by itself.
    var canRetry: Bool {
        switch self {
        case .listNotKnown, .signFailed: return true
        default: return false
        }
    }
}

extension MediaServersDraft {
    /// Whether Save would leave the published list with no public server, so
    /// Save is refused before anything is stored (web's `serverProblem`).
    /// `published`: the account's published list as this device last saw it,
    /// nil when unknown (then Save goes ahead, and the publish reports it).
    /// `others`: servers this device adds that aren't typed (the desktop
    /// vault's https address). Typed servers removed on this screen don't count.
    func leavesNoPublicServer(published: [String]?, others: [String] = []) -> Bool {
        guard let published else { return false }
        func key(_ url: String) -> String {
            var k = url.trimmingCharacters(in: .whitespaces).lowercased()
            while k.hasSuffix("/") { k.removeLast() }
            return k
        }
        let removed = Set(savePlanRemovedMirrors.map(key))
        let left = savePlan.mirrors + others + published.filter { !removed.contains(key($0)) }
        return !left.contains(where: HomeVaultLogic.isPublicServer)
    }

    /// Typed servers this Save takes off.
    private var savePlanRemovedMirrors: [String] {
        let now = Set(savePlan.mirrors)
        return savedMirrors.filter { !now.contains($0) }
    }
}
