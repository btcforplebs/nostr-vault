import SwiftUI

struct ActionButton: View {
    /// How loudly a button asks to be pressed. The relay dashboard offers five
    /// actions at once; rendering them all as filled accent tiles meant nothing
    /// signalled which one you came here for.
    enum Emphasis {
        /// Filled accent. The action this group exists for.
        case primary
        /// Tinted outline. Supporting actions that sit beside the primary one.
        case secondary
    }

    let icon: String
    let title: String
    var isLoading: Bool = false
    var emphasis: Emphasis = .primary
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var foreground: Color {
        emphasis == .primary ? .onAccent : Color.havenPurpleLight
    }

    private var isHighlighted: Bool { isHovered && isEnabled }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .colorScheme(.dark)
                } else {
                    Image(systemName: icon)
                        .font(.appSystem(size: 20, weight: .medium))
                        .foregroundColor(foreground)
                }
                Text(title)
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(foreground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(background)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: emphasis == .primary ? 0.5 : 1)
            )
            // Disabled controls have to *look* disabled: SwiftUI dims a plain
            // button style so little that the grid read as fully live while the
            // relay was stopped.
            .opacity(isEnabled ? 1.0 : 0.4)
            .scaleEffect(isHighlighted ? 1.03 : 1.0)
            .shadow(color: Color.havenPurple.opacity(isHighlighted && emphasis == .primary ? 0.35 : 0.0), radius: 8, x: 0, y: 4)
            .animation(Motion.control, value: isHovered)
            .animation(Motion.control, value: isEnabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(isLoading ? Text("In progress") : Text("Runs the \(title) task"))
    }

    @ViewBuilder
    private var background: some View {
        switch emphasis {
        case .primary:
            LinearGradient(
                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleDark]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            Color.havenPurple.opacity(isHighlighted ? 0.20 : 0.12)
        }
    }

    private var borderColor: Color {
        switch emphasis {
        case .primary:
            return Color.onAccent.opacity(0.12)
        case .secondary:
            return Color.havenPurple.opacity(isHighlighted ? 0.65 : 0.4)
        }
    }
}
