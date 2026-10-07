import SwiftUI

/// Event Info's Trust Path card: you on the left, the author on the right,
/// and the people you follow who follow them in between. Fixed layout and a
/// single line-draw animation, so nothing keeps redrawing while it's open.
struct TrustPathCard: View {
    let author: String
    @EnvironmentObject var nostrService: NostrService

    @State private var path: TrustPath?

    private var me: String { ConfigService.shared.activeAccountHexPubkey }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                avatar(me, size: 32)
                if let path {
                    TrustPathLine(lit: path.reach != .outside && path.reach != .unknown,
                                  broken: path.reach == .outside)
                    if !path.bridges.isEmpty {
                        HStack(spacing: -10) {
                            ForEach(path.bridges, id: \.self) { avatar($0, size: 26) }
                        }
                        TrustPathLine(lit: true, broken: false)
                    }
                } else {
                    Spacer(minLength: 16)
                }
                avatar(author, size: 32)
            }
            .frame(maxWidth: .infinity)

            Text(label)
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trust path. \(label)"))
        .task(id: author) {
            let found = await TrustPathService.shared.path(for: author)
            nostrService.fetchMissingProfiles(for: [me] + found.bridges)
            path = found
        }
    }

    private func avatar(_ pubkey: String, size: CGFloat) -> some View {
        AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size)
            .overlay(Circle().stroke(Color.platformTertiaryGroupedBackground, lineWidth: 2))
    }

    private func name(_ pubkey: String) -> String {
        nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }

    private var bridgeNames: String {
        guard let path else { return "" }
        let names = path.bridges.prefix(2).map(name)
        let rest = path.bridges.count - names.count
        if rest > 0 || path.hasMore { return names.joined(separator: ", ") + " + more" }
        return names.joined(separator: " and ")
    }

    private var label: String {
        guard let path else { return "Tracing how they reach you…" }
        switch path.reach {
        case .you:
            return "This is you."
        case .follow:
            return path.bridges.isEmpty
                ? "You follow them · 1 hop"
                : "You follow them · also followed by \(bridgeNames)"
        case .bridged:
            return "Followed by \(bridgeNames) you follow · 2 hops"
        case .web:
            return "In your Web of Trust"
        case .outside:
            return "Not in your web · no one you follow follows them"
        case .unknown:
            return "Your trust graph isn't loaded yet"
        }
    }
}

/// A line between two stops on the card. Draws itself once when it appears,
/// then stays still. Dashed and cut short when the author is outside your web.
private struct TrustPathLine: View {
    let lit: Bool
    let broken: Bool
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let y = geo.size.height / 2
            Path { p in
                p.move(to: CGPoint(x: 4, y: y))
                p.addLine(to: CGPoint(x: geo.size.width * (broken ? 0.55 : 1) - 4, y: y))
            }
            .trim(from: 0, to: progress)
            .stroke(lit ? Color.accentColor : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: lit ? 2 : 1.5, lineCap: .round, dash: broken ? [3, 4] : []))
            .shadow(color: lit ? Color.accentColor.opacity(0.6) : .clear, radius: 3)
        }
        .frame(minWidth: 16, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { progress = 1 } }
    }
}
