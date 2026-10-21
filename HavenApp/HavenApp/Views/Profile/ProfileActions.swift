import SwiftUI

/// The pieces both profile screens build their action rows from, so your own
/// row and someone else's are drawn the same way.
@MainActor
enum ProfileActions {
    static let height: CGFloat = 32

    static func pill(_ title: String, icon: String, filled: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.appSystem(size: 12, weight: .semibold))
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundColor(filled ? .white : .havenPurple)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(filled ? Color.havenPurple : Color.havenPurple.opacity(0.12))
            .cornerRadius(6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    static func icon(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { iconLabel(icon) }
            .buttonStyle(.plain)
    }

    static func iconLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.appSystem(size: 13, weight: .semibold))
            .foregroundColor(.havenPurple)
            .frame(width: height + 4, height: height)
            .background(Color.havenPurple.opacity(0.12))
            .cornerRadius(6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The WoT tab's globe, so the button and the tab read as one place.
    static func trustWeb(hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image("WoTTab")
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundColor(.havenPurple)
                .frame(width: height + 4, height: height)
                .background(Color.havenPurple.opacity(0.12))
                .cornerRadius(6)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Web of Trust")
        .accessibilityHint(hint)
    }

    /// A small capsule next to the name: YOU, MUTUAL, FOLLOWING, FOLLOWS YOU.
    static func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.appSystem(size: 9, weight: .heavy))
            .tracking(0.8)
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .cornerRadius(4)
    }
}

/// Text helpers both profile screens use.
enum ProfileFormat {
    static func shortInt(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", Double(n) / 1_000)
        }
        return "\(n)"
    }

    static func shortPubkey(_ pubkey: String) -> String {
        String(pubkey.prefix(8)) + "…" + String(pubkey.suffix(4))
    }

    static func npub(_ pubkey: String) -> String? {
        guard let data = Bech32.hexToData(pubkey) else { return nil }
        return Bech32.encode(hrp: "npub", data: data)
    }

    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
