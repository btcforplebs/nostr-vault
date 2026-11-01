import SwiftUI

/// "Switched to <name>": a gray bubble in the middle of the screen with the
/// account's picture, shown for a moment when the app switches account on
/// its own (a Vault line for another account was opened). Drawn on iOS by
/// the banner window (SceneDelegate); it takes no touches.
@MainActor
final class AccountSwitchFlash: ObservableObject {
    static let shared = AccountSwitchFlash()

    /// The account just switched to, by hex, while the bubble is up.
    @Published private(set) var shown: String?
    private var hideTask: Task<Void, Never>?

    /// How long the bubble stays fully on screen.
    static let holdSeconds: Double = 1.1

    func show(hex: String) {
        hideTask?.cancel()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { shown = hex.lowercased() }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.holdSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { shown = nil }
        }
    }
}

struct AccountSwitchFlashLayer: View {
    @ObservedObject private var flash = AccountSwitchFlash.shared

    var body: some View {
        ZStack {
            if let hex = flash.shown {
                AccountSwitchBubble(hex: hex)
                    .id(hex)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct AccountSwitchBubble: View {
    let hex: String
    @ObservedObject private var nostrService = NostrService.shared

    private var name: String {
        nostrService.profiles[hex]?.bestName ?? "npub…" + String(hex.suffix(6))
    }

    var body: some View {
        VStack(spacing: 12) {
            AvatarView(url: nostrService.profiles[hex]?.pictureURL, pubkey: hex, size: 72)
            Text("Switched to \(name)")
                .font(.appSystem(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(minWidth: 200, maxWidth: 280)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.22).opacity(0.94)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Switched to \(name)")
    }
}
