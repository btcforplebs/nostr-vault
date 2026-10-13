import SwiftUI

// MARK: - Follow Notification Model

struct FollowNotification: Identifiable {
    let id = UUID()
    let recipientName: String
    var kind: Kind
    /// Set on a pending pill, so the follow that finally lands can find it.
    var pubkey: String? = nil
    /// Reverses the follow or unfollow this pill confirms.
    var undo: (() -> Void)? = nil

    enum Kind: Equatable {
        case followed
        case unfollowed
        /// Tapped before the follow list had loaded: the tap is queued and
        /// applied once the list is confirmed. Not an error, so not red.
        case pending(follow: Bool)
        case failed(String)
    }
}

// MARK: - Follow Notification Manager

@MainActor
class FollowNotificationManager: ObservableObject {
    static let shared = FollowNotificationManager()

    @Published var notifications: [FollowNotification] = []

    func add(recipientName: String, kind: FollowNotification.Kind, undo: (() -> Void)? = nil) {
        let notification = FollowNotification(recipientName: recipientName, kind: kind, undo: undo)
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        // Long enough to reach Undo.
        scheduleDismiss(notification.id, after: undo == nil ? dismissDelay(kind) : 5.0)
    }

    /// Runs a pill's Undo and takes the pill down.
    func undo(_ id: UUID) {
        guard let notification = notifications.first(where: { $0.id == id }) else { return }
        withAnimation(Motion.bannerOut) { notifications.removeAll { $0.id == id } }
        notification.undo?()
    }

    /// A follow or unfollow queued until the follow list loads. The pill
    /// stays, with a spinner, until `resolvePending` replaces it.
    func addPending(pubkey: String, recipientName: String, follow: Bool) {
        if let idx = notifications.firstIndex(where: { $0.pubkey == pubkey }) {
            notifications[idx].kind = .pending(follow: follow)
            return
        }
        let notification = FollowNotification(recipientName: recipientName, kind: .pending(follow: follow), pubkey: pubkey)
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
    }

    /// The queued action was applied: the pending pill becomes the
    /// confirmation. `nil` drops it without one.
    func resolvePending(pubkey: String, kind: FollowNotification.Kind?) {
        guard let idx = notifications.firstIndex(where: { $0.pubkey == pubkey }) else { return }
        let id = notifications[idx].id
        guard let kind else {
            withAnimation(Motion.bannerOut) { notifications.removeAll { $0.id == id } }
            return
        }
        withAnimation(Motion.fade) {
            notifications[idx].kind = kind
            notifications[idx].pubkey = nil
        }
        scheduleDismiss(id, after: dismissDelay(kind))
    }

    /// The queue was discarded (account switch): nothing will land.
    func clearPending() {
        withAnimation(Motion.bannerOut) {
            notifications.removeAll { $0.pubkey != nil }
        }
    }

    private func dismissDelay(_ kind: FollowNotification.Kind) -> TimeInterval {
        if case .failed = kind { return 5.0 }
        return 3.0
    }

    private func scheduleDismiss(_ id: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            withAnimation(Motion.bannerOut) {
                self?.notifications.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Follow Notification Banner

struct FollowNotificationBanner: View {
    @ObservedObject private var manager = FollowNotificationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(manager.notifications) { notification in
                PillSlot("follow-\(notification.id)", level: notification.pillLevel) {
                    FollowPill(notification: notification)
                }
            }
        }
    }
}

extension FollowNotification {
    var pillLevel: PillLevel {
        if case .failed = kind { return .error }
        return .result
    }
}

// MARK: - Follow Pill

struct FollowPill: View {
    let notification: FollowNotification

    var body: some View {
        HStack(spacing: 6) {
            if case .pending = notification.kind {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            } else {
                Image(systemName: iconName)
                    .font(PillSize.regular.iconFont)
            }

            Text(label)
                .lineLimit(1)

            if notification.undo != nil {
                PillButton("Undo") { FollowNotificationManager.shared.undo(notification.id) }
            }
        }
        // With Undo, the 44 pt button sets the height.
        .pillCapsule(tone, vertical: notification.undo == nil ? nil : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityActions {
            if notification.undo != nil {
                Button("Undo") { FollowNotificationManager.shared.undo(notification.id) }
            }
        }
    }

    private var iconName: String {
        switch notification.kind {
        case .followed:   return "person.badge.plus"
        case .unfollowed: return "person.badge.minus"
        case .pending:    return "clock"
        case .failed:     return "xmark"
        }
    }

    private var label: String {
        switch notification.kind {
        case .followed:           return "Followed \(notification.recipientName)"
        case .unfollowed:         return "Unfollowed \(notification.recipientName)"
        case .pending(let follow): return follow ? "Following \(notification.recipientName)…" : "Unfollowing \(notification.recipientName)…"
        case .failed(let reason): return reason
        }
    }

    private var tone: PillTone {
        switch notification.kind {
        case .followed:   return .success
        case .unfollowed: return .neutral
        case .pending:    return .neutral
        case .failed:     return .error
        }
    }
}

