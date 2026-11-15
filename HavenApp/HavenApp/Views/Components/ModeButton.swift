import SwiftUI

struct ModeButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var hasNotification: Bool = false
    let action: () -> Void

    private var accentTint: Color {
        Color.havenPurple
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? .onAccent : (hasNotification ? accentTint : .ink))
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)
                    .foregroundColor(isSelected ? .onAccent : (hasNotification ? accentTint : .ink))
            }
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? .havenPurple : (hasNotification ? accentTint.opacity(0.15) : Color.clear))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isSelected ? .havenPurple.opacity(0.5) : (hasNotification ? accentTint.opacity(0.4) : Color.clear), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .animation(Motion.toggle, value: isSelected)
            .animation(Motion.fade, value: hasNotification)
        }
        .buttonStyle(.plain)
    }
}
