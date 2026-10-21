import SwiftUI

// MARK: - Error Notification Model

struct ErrorNotification: Identifiable {
    let id = UUID()
    let message: String
    let icon: String

    enum Style { case error, warning }
    let style: Style
}

// MARK: - Error Notification Manager

@MainActor
class ErrorNotificationManager: ObservableObject {
    static let shared = ErrorNotificationManager()

    @Published var notifications: [ErrorNotification] = []

    func show(_ message: String, icon: String = "exclamationmark.triangle.fill", style: ErrorNotification.Style = .error) {
        let notification = ErrorNotification(message: message, icon: icon, style: style)
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        // Cap at 3 visible
        if notifications.count > 3 {
            withAnimation(Motion.bannerOut) {
                notifications = Array(notifications.prefix(3))
            }
        }
        // An error stays until it is tapped away; a warning goes after 5 s.
        guard style == .warning else { return }
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        withAnimation(Motion.bannerOut) {
            notifications.removeAll { $0.id == id }
        }
    }
}

// MARK: - Error Notification Banner

struct ErrorNotificationBanner: View {
    @ObservedObject private var manager = ErrorNotificationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(manager.notifications) { notification in
                PillSlot("error-\(notification.id)", level: .error) {
                    ErrorPill(notification: notification)
                        .onTapGesture { manager.dismiss(notification.id) }
                }
            }
        }
    }
}

// MARK: - Error Pill

struct ErrorPill: View {
    let notification: ErrorNotification

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notification.icon)
                .font(PillSize.regular.iconFont)
            Text(notification.message)
                .lineLimit(2)
        }
        .pillCapsule(notification.style == .error ? .error : .warning)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notification.message)
        .accessibilityHint(notification.style == .error ? "Tap to dismiss" : "")
        .accessibilityAddTraits(notification.style == .error ? .isButton : [])
    }
}
