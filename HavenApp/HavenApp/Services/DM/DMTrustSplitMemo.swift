import Foundation
import Combine

/// The inbox / requests split and the unread total, kept until something
/// they depend on changes. Conversations and the trust graph bump a
/// generation when set; blocks, muted words, "show hidden" and the account
/// are compared on each read, as they live outside `DMService`.
@MainActor
final class DMTrustSplitMemo {
    struct Key: Equatable {
        let blocked: Set<String>
        let mutes: MuteList
        let showsMuted: Bool
        let own: String
    }

    typealias Split = (inbox: [DMConversation], requests: [DMConversation], unread: Int)

    private var conversations: UInt64 = 0
    private var trust: UInt64 = 0
    private var memo: (conversations: UInt64, trust: UInt64, key: Key, split: Split)?

    func conversationsChanged() { conversations &+= 1 }
    func trustChanged() { trust &+= 1 }

    func split(_ key: Key, compute: () -> (inbox: [DMConversation], requests: [DMConversation])) -> Split {
        if let memo, memo.conversations == conversations, memo.trust == trust, memo.key == key {
            return memo.split
        }
        let (inbox, requests) = compute()
        let split: Split = (inbox, requests, inbox.reduce(0) { $0 + $1.unreadCount })
        memo = (conversations, trust, key, split)
        return split
    }
}

/// The unread total on its own, for the tab bar: it used to observe all of
/// `DMService` and redraw on every change to any conversation, even when the
/// number stayed the same.
@MainActor
final class DMUnreadBadge: ObservableObject {
    static let shared = DMUnreadBadge()
    @Published private(set) var count = 0

    func set(_ value: Int) {
        if value != count { count = value }
    }
}

extension DMService {
    /// Keeps `DMUnreadBadge` equal to `totalUnreadCount`: read after each
    /// change lands (objectWillChange fires before it), and when blocks or the
    /// mute list change outside this service.
    func followUnreadBadge() {
        DMUnreadBadge.shared.set(totalUnreadCount)
        objectWillChange
            .merge(with: NotificationCenter.default.publisher(for: MuteListStore.settled).map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                DMUnreadBadge.shared.set(self.totalUnreadCount)
            }
            .store(in: &cancellables)
    }
}
