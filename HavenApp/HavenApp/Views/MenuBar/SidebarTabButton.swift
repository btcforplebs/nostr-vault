import SwiftUI

struct SidebarTabButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(isSelected ? .onAccent : (isHovered ? .primary : .secondary))
                    .frame(width: 20, height: 20)
                
                Text(title)
                    .font(.appSystem(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .onAccent : (isHovered ? .primary : .secondary))
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.havenPurple : (isHovered ? Color.ink.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
