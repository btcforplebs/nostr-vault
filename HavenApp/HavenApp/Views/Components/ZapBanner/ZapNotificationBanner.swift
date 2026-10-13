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
        withAnimation(Motion.bannerIn) {
            notifications.insert(notification, at: 0)
        }
        return notification.id
    }

    func markSuccess(id: UUID) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .success
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }

    func markFailed(id: UUID, message: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            withAnimation(Motion.fade) {
                notifications[idx].status = .failed(message)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                withAnimation(Motion.bannerOut) {
                    self?.notifications.removeAll { $0.id == id }
                }
            }
        }
    }
}

// MARK: - Zap Notification Banner (floating pill)

struct ZapNotificationBanner: View {
    @ObservedObject private var zapManager = ZapNotificationManager.shared
    @ObservedObject private var unlikeManager = UnlikeNotificationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            if unlikeManager.isShowing {
                PillSlot("unlike", level: .result) {
                    UnlikePill(timeRemaining: unlikeManager.timeRemaining) {
                        unlikeManager.cancel()
                    }
                }
            }
            ForEach(zapManager.notifications) { notification in
                PillSlot("zap-\(notification.id)", level: notification.pillLevel) {
                    ZapPill(notification: notification)
                }
            }
        }
    }
}

extension ZapNotification {
    var pillLevel: PillLevel {
        if case .failed = status { return .error }
        return .result
    }
}

// MARK: - Zap Pill

struct ZapPill: View {
    let notification: ZapNotification
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        HStack(spacing: 6) {
            // Status icon
            statusIcon

            // Label
            Text(pillLabel)

            // Sats amount
            Text("\(notification.amountSats) sats")
                .monospacedDigit()
        }
        .pillCapsule(tone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pillLabel), \(notification.amountSats) sats")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch notification.status {
        case .sending:
            Image(systemName: "bolt.fill")
                .font(PillSize.regular.iconFont)
                .opacity(pulseOpacity)
                .onAppear {
                    // Same reason as the feed skeleton: without the guard the
                    // bolt would sit dimmed at 0.4 for the whole send.
                    guard let loop = Motion.ambientPulse else { return }
                    withAnimation(loop) { pulseOpacity = 0.4 }
                }
        case .success:
            Image(systemName: "bolt.fill")
                .font(PillSize.regular.iconFont)
        case .failed:
            Image(systemName: "xmark")
                .font(PillSize.regular.iconFont)
        }
    }

    private var pillLabel: String {
        switch notification.status {
        case .sending: return "Zapping \(notification.recipientName)"
        case .success: return "Zapped \(notification.recipientName)"
        case .failed:  return "Zap failed"
        }
    }

    private var tone: PillTone {
        switch notification.status {
        case .sending: return .accent
        case .success: return .success
        case .failed:  return .error
        }
    }
}
