import SwiftUI

// MARK: - Relay Activity Notification Model
//
// In-app "drop down" banner for relay NOTIFY events (like/reply/repost/zap/mention/DM)
// that arrive while the app is foregrounded — LocalNotificationService uses this instead
// of the system push in that case (paired with a sound, since suppressing the system
// notification also suppresses its sound). Tapping navigates the same place the system
// notification would.

struct RelayActivityNotification: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let body: String
    let color: Color
    let onTap: () -> Void
    /// Runs if the pill leaves without the lane ever drawing it, to file the
    /// alert in Notification Center instead. Nil when it is already there.
    let onMissed: (() -> Void)?

    /// The pill's id in the lane.
    var laneId: String { "relayActivity-\(id)" }
}

// MARK: - Relay Activity Notification Manager

@MainActor
final class RelayActivityNotificationManager: ObservableObject {
    static let shared = RelayActivityNotificationManager()
    private init() {}

    @Published var notifications: [RelayActivityNotification] = []

    func show(icon: String, title: String, body: String, color: Color,
              onTap: @escaping () -> Void, onMissed: (() -> Void)? = nil) {
        let notification = RelayActivityNotification(icon: icon, title: title, body: body, color: color,
                                                     onTap: onTap, onMissed: onMissed)
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        // Cap at 3 visible so a burst of activity doesn't fill the screen.
        if notifications.count > 3 {
            notifications.dropFirst(3).forEach { fileIfUnread($0, end: .trimmed) }
            withAnimation(Motion.bannerOut) {
                notifications = Array(notifications.prefix(3))
            }
        }
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.dismiss(id, end: .timedOut)
        }
    }

    func dismiss(_ id: UUID, end: NotificationPolicy.PillEnd) {
        notifications.filter { $0.id == id }.forEach { fileIfUnread($0, end: end) }
        withAnimation(Motion.bannerOut) {
            notifications.removeAll { $0.id == id }
        }
    }

    /// The surface these pills draw on went away: the app left the front, or
    /// the Mac's main window closed. Every pill still up is filed, read or
    /// not, and cleared, so none is lost with the window.
    func hostLost() {
        guard !notifications.isEmpty else { return }
        notifications.forEach { fileIfUnread($0, end: .hostLost) }
        notifications.removeAll()
    }

    /// The lane shows two pills at most, so in a burst an arrival can time
    /// out unseen or draw only for a moment. Those go to Notification Center.
    /// Asked before removal, while the lane still knows how long it drew.
    private func fileIfUnread(_ notification: RelayActivityNotification, end: NotificationPolicy.PillEnd) {
        guard let onMissed = notification.onMissed,
              NotificationPolicy.filesPill(end: end, drawnFor: PillLane.shared.drawnFor(notification.laneId))
        else { return }
        onMissed()
    }
}

// MARK: - Relay Activity Banner

struct RelayActivityBanner: View {
    @ObservedObject private var manager = RelayActivityNotificationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(manager.notifications) { notification in
                PillSlot(notification.laneId, level: .result) {
                    RelayActivityPill(notification: notification) {
                        manager.dismiss(notification.id, end: .tapped)
                    }
                }
            }
        }
    }
}

// MARK: - Relay Activity Pill

struct RelayActivityPill: View {
    let notification: RelayActivityNotification
    let onDismiss: () -> Void

    var body: some View {
        Button {
            onDismiss()
            notification.onTap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: notification.icon)
                    .font(PillSize.regular.iconFont)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notification.title)
                        .lineLimit(1)
                    if !notification.body.isEmpty {
                        Text(notification.body)
                            .font(.appSystem(size: 12, weight: .regular))
                            .lineLimit(1)
                            .opacity(0.85)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 300)
            // The icon says what arrived; the colour is the lane's accent.
            .pillCapsule(.accent)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notification.body.isEmpty ? notification.title : "\(notification.title). \(notification.body)")
    }
}
