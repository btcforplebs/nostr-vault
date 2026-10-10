import SwiftUI

/// The quick menu a tap on a post's profile picture opens: follow or
/// unfollow, Web of Trust, and block. Full posts, condensed rows and thread
/// lines all draw this one, so the photo means the same thing everywhere.
struct AuthorQuickMenu: View {
    let pubkey: String
    let displayName: String
    let isFollowed: Bool
    /// Drives the pop-in; the caller flips it with the menu's visibility.
    let expanded: Bool
    /// Opens the trust web on `pubkey`. The caller owns the sheet.
    let onWebOfTrust: () -> Void
    let dismiss: () -> Void

    @Environment(\.feedActions) private var actions

    var body: some View {
        VStack(spacing: 2) {
            glassIcon(isFollowed ? "person.badge.minus.fill" : "person.badge.plus",
                      tint: isFollowed ? .yellow : .green, index: 0) {
                if isFollowed { actions.unfollowUser(pubkey) }
                else { actions.followUser(pubkey) }
                dismiss()
            }
            .accessibilityLabel(isFollowed ? "Unfollow \(displayName)" : "Follow \(displayName)")
            // The post footer's old WoT button, next to the person it's about.
            glassIcon("WoTTab", asset: true, tint: .havenPurple, index: 1) {
                onWebOfTrust()
                dismiss()
            }
            .accessibilityLabel("Web of Trust")
            .accessibilityHint("Shows how you're connected to \(displayName)")
            // Block last and set apart, so it's never a slip from the globe.
            Divider().frame(width: 20).padding(.vertical, 2)
                .scaleEffect(expanded ? 1 : 0.01)
                .opacity(expanded ? 1 : 0)
            glassIcon("hand.raised.fill", tint: .red, index: 2) {
                actions.blockUser(pubkey)
                ActionToastManager.shared.show(
                    icon: "hand.raised.fill",
                    message: "Blocked \(displayName)",
                    color: .red
                )
                dismiss()
            }
            .accessibilityLabel("Block \(displayName)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .modifier(LiquidGlassVerticalModifier())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func glassIcon(_ icon: String, asset: Bool = false, tint: Color = .white, index: Int,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if asset {
                    // A template image doesn't follow the font like an SF Symbol does.
                    Image(icon).resizable().frame(width: 17, height: 17)
                } else {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(tint.opacity(0.85))
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(expanded ? 1 : 0.01)
        .opacity(expanded ? 1 : 0)
        .animation(
            Motion.staggered(Motion.pop, index: index, step: 0.06),
            value: expanded
        )
    }
}

struct LiquidGlassVerticalModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    func body(content: Content) -> some View {
        if #available(iOS 26, macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(Color.havenPurple.opacity(0.06))
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.12), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    }
                }
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                )
        }
    }
}

