import SwiftUI

/// One Your space panel: the web's card, with its header line (icon, name,
/// count, a chevron that collapses it to that line) and, while Your space is
/// being edited, buttons to move it up or down and to take it off.
struct SpacePanelCard<Content: View>: View {
    let title: String
    let symbol: String
    var count: Int = 0
    let open: Bool
    let editing: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleOpen: () -> Void
    let onMove: (Int) -> Void
    let onHide: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
            if open && !editing {
                Divider().opacity(0.6)
                content()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(editing ? 0.5 : 0.28), lineWidth: 1)
        )
        .shadow(color: Color.havenPurple.opacity(0.18), radius: 14, y: 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.havenPurple.opacity(0.15)))
                .accessibilityHidden(true)
            Text(title)
                .font(.appSystem(size: 15, weight: .bold))
                .lineLimit(1)
            if let badge = AccountUnread.badge(count) {
                Text(badge)
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.havenPurple))
            }
            Spacer(minLength: 4)
            if editing {
                editButton("chevron.up", label: "Move \(title) up", enabled: canMoveUp) { onMove(-1) }
                editButton("chevron.down", label: "Move \(title) down", enabled: canMoveDown) { onMove(1) }
                editButton("eye.slash", label: "Remove \(title)", enabled: true, action: onHide)
            } else {
                Button(action: onToggleOpen) {
                    Image(systemName: "chevron.down")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .accessibilityLabel(open ? "Collapse \(title)" : "Open \(title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { if !editing { onToggleOpen() } }
    }

    private func editButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.appSystem(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundColor(enabled ? .white : .secondary.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
