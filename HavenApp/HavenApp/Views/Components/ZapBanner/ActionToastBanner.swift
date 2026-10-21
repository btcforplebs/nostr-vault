import SwiftUI

// MARK: - Action Toast Manager

@MainActor
class ActionToastManager: ObservableObject {
    static let shared = ActionToastManager()

    struct Toast: Identifiable {
        let id = UUID()
        let icon: String
        let message: String
        let tone: PillTone
    }

    @Published var notifications: [Toast] = []

    /// Feedback on a tap: small, and replaced by the next one. An error or
    /// warning tone goes to `ErrorNotificationManager` instead, so every
    /// failure looks and lasts the same.
    func show(icon: String, message: String, tone: PillTone = .accent, seconds: Double = 2.5) {
        if tone == .error || tone == .warning {
            ErrorNotificationManager.shared.show(message, icon: icon, style: tone == .error ? .error : .warning)
            return
        }
        let toast = Toast(icon: icon, message: message, tone: tone)
        notifications.append(toast)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            withAnimation(Motion.bannerOut) {
                notifications.removeAll { $0.id == toast.id }
            }
        }
    }
}

/// The short "Liked" pill after a like is signed and sent. A like signed by a
/// remote signer takes a round trip, and with nothing on screen there was no
/// telling a like that went out from one the signer never answered.
@MainActor
enum LikeFeedback {
    static func liked(_ emoji: String? = nil) {
        let shown = emoji.map(reactionDisplayEmoji) ?? ""
        let message = shown.isEmpty || shown == "❤️" ? "Liked" : "Reacted \(shown)"
        ActionToastManager.shared.show(icon: "heart.fill", message: message)
    }

    static func failed() {
        ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                       message: "Like failed: your signer didn't answer",
                                       tone: .error)
    }
}

// MARK: - Action Toast Banner

struct ActionToastBanner: View {
    @ObservedObject private var manager = ActionToastManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ForEach(manager.notifications) { toast in
                PillSlot("toast-\(toast.id)", level: .feedback) {
                    HStack(spacing: 5) {
                        Image(systemName: toast.icon)
                            .font(PillSize.small.iconFont)
                        Text(toast.message)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .pillCapsule(toast.tone, size: .small)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
