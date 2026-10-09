import SwiftUI

struct FilterButton: View {
    let title: String
    var icon: String? = nil
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.appSystem(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.appSystem(size: 11, weight: isSelected ? .bold : .regular, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .white : .secondary)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? color.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
            // An unselected pill has a clear fill, and a .plain button only
            // takes clicks where something is drawn: on the Mac, the padding
            // around the title was dead.
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(Motion.toggle, value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
