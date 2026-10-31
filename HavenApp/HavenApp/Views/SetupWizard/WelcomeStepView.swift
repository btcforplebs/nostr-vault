import SwiftUI

// MARK: - Step 0: Welcome (the front door)

/// The first screen after install. It used to be five feature paragraphs with
/// Get Started below the fold, then a separate "how do you want to use it"
/// screen whose Continue only appeared after picking a card. Now it fits one
/// phone screen and the three ways in are the buttons themselves.
struct WelcomeStepView: View {
    let onChoose: (SetupWizardView.SetupPath) -> Void

    @State private var appeared = false
    @State private var showWhatsInside = false

    var body: some View {
        GeometryReader { proxy in
            // Tall phones get a bigger icon so the block fills the space
            // instead of floating; the SE is already tight.
            let iconSize: CGFloat = proxy.size.height > 800 ? 112 : 92

            VStack(spacing: 0) {
                // Centred in the space above the buttons. When it can't fit
                // (large text scale), only this part scrolls and the buttons
                // stay pinned.
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 16)
                        hero(iconSize: iconSize)
                        Spacer(minLength: 16)
                    }
                    ScrollView {
                        hero(iconSize: iconSize).padding(.vertical, 24)
                    }
                }
                .frame(maxHeight: .infinity)

                actions
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }
            // A GeometryReader puts its child at the top leading corner. On the
            // Mac the buttons stop at 360 pt, so without this the block hugs the
            // left of the window; on iPhone they already fill the width.
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showWhatsInside) {
            WhatsInsideSheet()
        }
        .onAppear {
            if Motion.isReduced {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            }
        }
    }

    // MARK: Hero

    private func hero(iconSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            vaultMark(size: iconSize)
                .scaleEffect(appeared ? 1 : 0.92)
                .accessibilityHidden(true)

            Text("Nostr Vault")
                .font(.appSystem(size: 34, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .padding(.top, 24)
                .accessibilityAddTraits(.isHeader)

            // Broken by hand so it splits at the comma on every width.
            Text("Your posts, messages and media,\nkept on your own device.")
                .font(.appSystem(size: 17))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            chips
                .padding(.top, 24)

            Button { showWhatsInside = true } label: {
                Text("What's inside?")
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(WizardColors.accentPrimary)
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
        .opacity(appeared ? 1 : 0)
    }

    /// The icon they just tapped on the home screen, so the first screen
    /// matches it. Exported from the 1024 AppIcon: `Image("AppIcon")` does not
    /// load reliably on iOS.
    private func vaultMark(size: CGFloat) -> some View {
        let corner = size * 0.2237 // the iOS icon squircle's ratio
        return ZStack {
            Circle()
                .fill(WizardColors.accentPrimary.opacity(0.35))
                .frame(width: size * 1.6, height: size * 1.6)
                .blur(radius: 40)

            Image("VaultMark")
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .frame(height: size + 4)
    }

    // MARK: Chips

    private static let chipItems: [(icon: String, label: String)] = [
        ("externaldrive.connected.to.line.below", "Own vault"),
        ("lock.shield", "Private DMs"),
        ("bolt.fill", "Zaps")
    ]

    /// One row when it fits, two rows on a narrow phone, a column at large
    /// text. Not buttons: they describe, they don't do anything.
    private var chips: some View {
        let items = Self.chipItems
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.label) { chip($0.icon, $0.label) }
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items.prefix(2), id: \.label) { chip($0.icon, $0.label) }
                }
                ForEach(items.suffix(1), id: \.label) { chip($0.icon, $0.label) }
            }
            VStack(spacing: 8) {
                ForEach(items, id: \.label) { chip($0.icon, $0.label) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Includes your own relay, private DMs and zaps")
    }

    private func chip(_ icon: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.accentPrimary)
            Text(label)
                .font(.appSystem(size: 13, weight: .medium))
                .foregroundColor(WizardColors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(Capsule().fill(WizardColors.bgCard))
        .overlay(Capsule().stroke(WizardColors.borderSubtle, lineWidth: 1))
        .fixedSize()
    }

    // MARK: Actions

    /// No entrance delay: these are tappable on the first frame.
    private var actions: some View {
        VStack(spacing: 12) {
            Button { onChoose(.newToNostr) } label: {
                Text("Create an account").font(.appSystem(size: 17, weight: .semibold))
            }
            .buttonStyle(FrontDoorButtonStyle(isPrimary: true))

            // iPhone/iPad: one key field on the next step decides read-only
            // vs can-post, so this one button covers both. The Mac still
            // offers browse separately.
            Button { onChoose(isIOSDevice ? .useNostr : .full) } label: {
                Text("I already use Nostr").font(.appSystem(size: 17, weight: .semibold))
            }
            .buttonStyle(FrontDoorButtonStyle(isPrimary: false))

            if !isIOSDevice {
                Button { onChoose(.browse) } label: {
                    Text("Just look around")
                        .font(.appSystem(size: 15, weight: .medium))
                        .foregroundColor(WizardColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: isIOSDevice ? .infinity : 360)
    }
}

private struct FrontDoorButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(WizardColors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                if isPrimary {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WizardColors.accentGradient)
                        .shadow(color: WizardColors.accentGlow, radius: 8, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(WizardColors.bgCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(WizardColors.borderSubtle, lineWidth: 1)
                        )
                }
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(WizardAnimations.springGentle, value: configuration.isPressed)
    }
}
