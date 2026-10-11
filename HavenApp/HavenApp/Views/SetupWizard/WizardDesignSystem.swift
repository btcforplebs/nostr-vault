import SwiftUI

// MARK: - Design System

enum WizardColors {
    static let bgPrimary = Color(red: 0.035, green: 0.035, blue: 0.043)      // #09090B
    static let bgCard = Color(red: 0.094, green: 0.094, blue: 0.106)          // #18181B
    static let bgElevated = Color(red: 0.153, green: 0.153, blue: 0.165)      // #27272A
    static let accentPrimary = Color(red: 0.961, green: 0.620, blue: 0.043)   // #F59E0B
    static let accentGlow = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.3)
    static let textPrimary = Color(red: 0.980, green: 0.980, blue: 0.980)     // #FAFAFA
    static let textSecondary = Color(red: 0.631, green: 0.631, blue: 0.667)   // #A1A1AA
    static let textMuted = Color(red: 0.443, green: 0.443, blue: 0.478)       // #71717A
    /// Was #27272A — identical to `bgElevated`, so any control stroked in it while
    /// sitting on an elevated row had 1:1 contrast and was invisible (the unselected
    /// follow checkbox). `Color.borderStrong` (white 36%) is the token `Theming.swift`
    /// defines for exactly this case: a border that is the only cue for a control.
    /// 3.23:1 against `bgElevated`, 3.75:1 against `bgCard`.
    static let borderSubtle = Color.borderStrong
    static let borderActive = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.5)
    static let success = Color(red: 0.133, green: 0.773, blue: 0.369)         // #22C55E
    static let error = Color(red: 0.937, green: 0.267, blue: 0.267)           // #EF4444

    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.918, green: 0.345, blue: 0.047), Color(red: 0.961, green: 0.620, blue: 0.043)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// Onboarding runs slower than the rest of the app on purpose — it is the one
/// place the user is being walked through something rather than operating it.
/// These keep that tempo but route through `Motion.custom`, so the wizard's ~80
/// animation call sites pick up Reduce Motion without each one being touched.
enum WizardAnimations {
    static var springEnter: Animation { Motion.custom(response: 0.6, dampingFraction: 0.8) }
    static var springBounce: Animation { Motion.custom(response: 0.5, dampingFraction: 0.6) }
    static var springGentle: Animation { Motion.custom(response: 0.8, dampingFraction: 0.9) }
    static let fadeIn: Animation = .easeOut(duration: 0.4)
    static let staggerDelay: Double = 0.08
}

// MARK: - Shared Components

struct WizardPrimaryButton: View {
    let title: String
    let action: () -> Void
    var disabled: Bool = false

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(WizardColors.textPrimary)
                .frame(maxWidth: isIOSDevice ? .infinity : nil, minHeight: 44)
                .padding(.horizontal, isIOSDevice ? 0 : 32)
                .background(WizardColors.accentGradient)
                .cornerRadius(12)
                .shadow(color: WizardColors.accentGlow, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .opacity(disabled ? 0.4 : 1.0)
        .disabled(disabled)
        .animation(WizardAnimations.springGentle, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

struct WizardSkipLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appSystem(size: 14))
                .foregroundColor(WizardColors.textMuted)
        }
        .buttonStyle(.plain)
    }
}

struct WizardGlassCard<Content: View>: View {
    var isSelected: Bool = false
    let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .background(WizardColors.bgCard)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? WizardColors.accentGlow : .clear, radius: 12)
    }
}

struct WizardInputField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var isSecure: Bool = false
    var isDisabled: Bool = false
    /// When set (iOS only), a QR scan button is shown inside the field.
    var onScan: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.appSystem(size: 13))
                .foregroundColor(WizardColors.textSecondary)

            HStack(spacing: 8) {
                Group {
                    if isSecure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textPrimary)
                .focused($isFocused)
                .disabled(isDisabled)

                #if os(iOS)
                if let onScan {
                    Button(action: onScan) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.appSystem(size: 20))
                            .foregroundColor(WizardColors.accentPrimary)
                            .frame(width: 36, height: 36)
                            .background(WizardColors.bgElevated)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityLabel("Scan QR code")
                }
                #endif
            }
            .padding(12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? WizardColors.borderActive : WizardColors.borderSubtle, lineWidth: isFocused ? 2 : 1)
            )
        }
    }
}

// MARK: - Shared Tab Pill

func tabPill(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title)
            .font(.appSystem(size: 14, weight: .medium))
            .foregroundColor(isActive ? WizardColors.textPrimary : WizardColors.textMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isActive ? WizardColors.accentPrimary : Color.clear)
            .cornerRadius(8)
    }
    .buttonStyle(.plain)
}
