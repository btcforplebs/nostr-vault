import SwiftUI

struct RelayRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let uri: String
    let endpoint: String

    @State private var copied = false
    @State private var isHovered = false

    var fullURI: String {
        return uri + endpoint
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.appSystem(size: 15, weight: .semibold))
                .foregroundColor(Color.havenPurple)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.ink)
                Text(subtitle)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(fullURI)
                .font(.appSystem(size: 10, design: .monospaced))
                .foregroundColor(copied ? .green : Color.havenPurpleLight)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.shade.opacity(copied ? 0.5 : 0.35))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(copied ? Color.green.opacity(0.6) : Color.havenPurple.opacity(0.3), lineWidth: 1)
                )
                .scaleEffect(copied ? 1.05 : 1.0)
                .animation(Motion.pop, value: copied)

            Button(action: {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullURI, forType: .string)
                #else
                UIPasteboard.general.string = fullURI
                #endif
                withAnimation(Motion.fade) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(Motion.fade) { copied = false }
                }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? Color.platformSecondaryGroupedBackground : Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isHovered ? Color.havenPurple.opacity(0.2) : Color.ink.opacity(0.03), lineWidth: 0.5)
        )
        .animation(Motion.control, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
