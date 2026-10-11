import SwiftUI

struct TabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.appSystem(size: 16, weight: isSelected ? .semibold : .medium))
                    .scaleEffect(isSelected ? 1.1 : 1.0)
                Text(title)
                    .font(.appSystem(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? Color.havenPurple : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
