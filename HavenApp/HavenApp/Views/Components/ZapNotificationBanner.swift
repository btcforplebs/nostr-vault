import SwiftUI

// MARK: - Zap Notification Model

struct ZapNotification: Identifiable {
    let id = UUID()
    let recipientName: String
    let amountSats: Int
    var status: ZapStatus

    enum ZapStatus: Equatable {
        case sending
        case success
        case failed(String)
    }
}

// MARK: - Zap Notification Manager

@MainActor
class ZapNotificationManager: ObservableObject {
    static let shared = ZapNotificationManager()

    @Published var notifications: [ZapNotification] = []

    func addZap(recipientName: String, amountSats: Int) -> UUID {
        let notification = ZapNotification(
            recipientName: recipientName,
            amountSats: amountSats,
            status: .sending
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        return notification.id
    }

    func markSuccess(id: UUID) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .success
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(.easeInOut(duration: 0.3)) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(.easeOut(duration: 0.4)) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }
}

// MARK: - Zap Notification Banner (floating pill)

struct ZapNotificationBanner: View {
    @ObservedObject private var manager = ZapNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                ZapPill(notification: notification)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
    }
}

// MARK: - Zap Pill (matches "New Posts" capsule style)

struct ZapPill: View {
    let notification: ZapNotification
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            // Status icon
            statusIcon

            // Label
            Text(pillLabel)
                .font(.system(size: 13, weight: .bold))

            // Sats amount
            Text("\(notification.amountSats) sats")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch notification.status {
        case .sending:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
                .opacity(pulseOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                        pulseOpacity = 0.4
                    }
                }
        case .success:
            Image(systemName: "bolt.fill")
                .font(.system(size: 12, weight: .bold))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
        }
    }

    private var pillLabel: String {
        switch notification.status {
        case .sending: return "Zapping \(notification.recipientName)"
        case .success: return "Zapped \(notification.recipientName)"
        case .failed:  return "Zap failed"
        }
    }

    private var pillColor: Color {
        switch notification.status {
        case .sending: return .orange
        case .success: return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .failed:  return .red.opacity(0.85)
        }
    }
}

// MARK: - Follow Notification Model

struct FollowNotification: Identifiable {
    let id = UUID()
    let recipientName: String
    let kind: Kind

    enum Kind: Equatable {
        case followed
        case unfollowed
        case failed(String)
    }
}

// MARK: - Follow Notification Manager

@MainActor
class FollowNotificationManager: ObservableObject {
    static let shared = FollowNotificationManager()

    @Published var notifications: [FollowNotification] = []

    func add(recipientName: String, kind: FollowNotification.Kind) {
        let notification = FollowNotification(recipientName: recipientName, kind: kind)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            notifications.insert(notification, at: 0)
        }
        let dismissDelay: TimeInterval = {
            if case .failed = kind { return 5.0 }
            return 3.0
        }()
        let id = notification.id
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) { [weak self] in
            withAnimation(.easeOut(duration: 0.4)) {
                self?.notifications.removeAll { $0.id == id }
            }
        }
    }
}

// MARK: - Follow Notification Banner

struct FollowNotificationBanner: View {
    @ObservedObject private var manager = FollowNotificationManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { notification in
                FollowPill(notification: notification)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.8))
                    ))
            }
        }
        .padding(.top, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: manager.notifications.map(\.id))
    }
}

// MARK: - Follow Pill

struct FollowPill: View {
    let notification: FollowNotification

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))

            Text(label)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .background(
            Capsule()
                .fill(pillColor)
                .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
        )
        .foregroundColor(.white)
    }

    private var iconName: String {
        switch notification.kind {
        case .followed:   return "person.badge.plus"
        case .unfollowed: return "person.badge.minus"
        case .failed:     return "xmark"
        }
    }

    private var label: String {
        switch notification.kind {
        case .followed:           return "Followed \(notification.recipientName)"
        case .unfollowed:         return "Unfollowed \(notification.recipientName)"
        case .failed(let reason): return reason
        }
    }

    private var pillColor: Color {
        switch notification.kind {
        case .followed:   return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .unfollowed: return Color(white: 0.35)
        case .failed:     return .red.opacity(0.85)
        }
    }
}
