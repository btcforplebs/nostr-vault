import SwiftUI

struct StatsCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var isLoading: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.appSystem(size: 16))
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8, anchor: .leading)
                        .frame(height: 24)
                } else {
                    Text(value)
                        .font(.appSystem(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.ink)
                }
                Text(title)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(isHovered ? color.opacity(0.08) : Color.platformCardBackground)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? color.opacity(0.4) : Color.platformCardBorder, lineWidth: 1.0)
        )
        .shadow(color: color.opacity(isHovered ? 0.18 : 0.0), radius: 8, x: 0, y: 3)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(Motion.control, value: isHovered)
    }

    var body: some View {
        Group {
            if let action = action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .onHover { hovering in
            withAnimation(Motion.control) { isHovered = hovering && action != nil }
        }
        // The card reads as icon + big number + caption, which VoiceOver would
        // otherwise announce as three unrelated fragments in the wrong order.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isLoading ? Text("Loading") : Text(value))
        .accessibilityAddTraits(action != nil ? .isButton : [])
        .accessibilityHint(action != nil ? Text("Shows a detailed breakdown") : Text(""))
    }
}
