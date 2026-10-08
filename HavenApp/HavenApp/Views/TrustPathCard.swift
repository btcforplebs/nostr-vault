import SwiftUI

/// Event Info's Trust Path card: you on the left, the author on the right,
/// and the people you follow who follow them in between. Fixed layout and a
/// single line-draw animation, so nothing keeps redrawing while it's open.
struct TrustPathCard: View {
    let author: String
    @EnvironmentObject var nostrService: NostrService

    @State private var path: TrustPath?
    /// iPad: the globe opens full screen instead of inside Event Info's sheet.
    @State private var showingWeb = false

    private var me: String { ConfigService.shared.activeAccountHexPubkey }

    var body: some View {
        Group {
            if let path, path.reach != .you {
                if TrustWebSheet.opensFullScreen {
                    Button { showingWeb = true } label: { card(chevron: true) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows your web of trust"))
                        .trustWebPresentation(isPresented: $showingWeb, author: author, path: path)
                } else {
                    NavigationLink {
                        TrustWebView(author: author, path: path)
                    } label: {
                        card(chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Shows your web of trust"))
                }
            } else {
                card(chevron: false)
            }
        }
        .task(id: author) {
            let found = await TrustPathService.shared.path(for: author)
            nostrService.fetchMissingProfiles(for: [me, author] + found.bridges)
            path = found
        }
    }

    private func card(chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                avatar(me, size: 32)
                if let path {
                    if path.reach != .you {
                        TrustPathLine(lit: path.reach != .outside && path.reach != .unknown,
                                      broken: path.reach == .outside)
                        if !path.bridges.isEmpty {
                            HStack(spacing: -10) {
                                ForEach(path.bridges, id: \.self) { avatar($0, size: 26) }
                            }
                            TrustPathLine(lit: true, broken: false)
                        }
                        avatar(author, size: 32)
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    // Same shape as the answer, so nothing jumps when it lands.
                    TrustPathLine(lit: false, broken: false, animated: false)
                        .opacity(0.5)
                    avatar(author, size: 32)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(14)
        .background(Color.platformTertiaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Trust path. \(label)"))
    }

    private func avatar(_ pubkey: String, size: CGFloat) -> some View {
        AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size)
            .overlay(Circle().stroke(Color.platformTertiaryGroupedBackground, lineWidth: 2))
    }

    private func name(_ pubkey: String) -> String {
        nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }

    private var label: String { TrustPathText.label(path, name: name) }
}

/// A line between two stops on the card. Draws itself once when it appears,
/// then stays still. Dashed and cut short when the author is outside your web.
private struct TrustPathLine: View {
    let lit: Bool
    let broken: Bool
    var animated = true
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let y = geo.size.height / 2
            Path { p in
                p.move(to: CGPoint(x: 4, y: y))
                p.addLine(to: CGPoint(x: geo.size.width * (broken ? 0.55 : 1) - 4, y: y))
            }
            .trim(from: 0, to: progress)
            .stroke(lit ? Color.havenPurple : Color.secondary.opacity(0.5),
                    style: StrokeStyle(lineWidth: lit ? 2 : 1.5, lineCap: .round, dash: broken ? [3, 4] : []))
            .shadow(color: lit ? Color.havenPurple.opacity(0.6) : .clear, radius: 3)
        }
        .frame(minWidth: 16, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .onAppear {
            if !animated || Motion.isReduced {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 0.6)) { progress = 1 }
            }
        }
    }
}
