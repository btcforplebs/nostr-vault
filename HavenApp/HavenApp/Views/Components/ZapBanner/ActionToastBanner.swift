import SwiftUI

// MARK: - Action Toast Manager

@MainActor
class ActionToastManager: ObservableObject {
    static let shared = ActionToastManager()

    struct Toast: Identifiable {
        let id = UUID()
        let icon: String
        let message: String
        let color: Color
    }

    @Published var notifications: [Toast] = []

    func show(icon: String, message: String, color: Color? = nil, seconds: Double = 2.5) {
        let toast = Toast(icon: icon, message: message, color: color ?? Color.havenPurple)
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
        ActionToastManager.shared.show(icon: "heart.fill", message: message, color: .pink)
    }

    static func failed() {
        ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill",
                                       message: "Like failed: your signer didn't answer",
                                       color: Color.red.opacity(0.85))
    }
}

// MARK: - Action Toast Banner

struct ActionToastBanner: View {
    @ObservedObject private var manager = ActionToastManager.shared

    var body: some View {
        VStack(spacing: 6) {
            ForEach(manager.notifications) { toast in
                HStack(spacing: 6) {
                    Image(systemName: toast.icon)
                        .font(.appSystem(size: 12, weight: .bold))
                    Text(toast.message)
                        .font(.appSystem(size: 13, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 20)
                .background(
                    Capsule()
                        .fill(toast.color)
                        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
                )
                .foregroundColor(.white)
                .transition(Motion.pillTransition)
            }
        }
        .padding(.top, manager.notifications.isEmpty ? 0 : 12)
        .animation(Motion.bannerIn, value: manager.notifications.map(\.id))
    }
}
