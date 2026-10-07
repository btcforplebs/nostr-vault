import SwiftUI

/// The Trust Path card opened up: you in the centre, your follows as a faint
/// ring, the author past it, and only the lines that actually reach them lit.
/// Every position is a fixed angle on a circle, worked out once from the view's
/// size, with no physics settling, and the lines draw once and stay still.
struct TrustWebView: View {
    let author: String
    let path: TrustPath
    @EnvironmentObject var nostrService: NostrService

    @State private var progress: CGFloat = 0
    @State private var profilePubkey: String?

    private var me: String { ConfigService.shared.activeAccountHexPubkey }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TrustWebGraph(me: me, author: author, path: path, progress: progress,
                              avatar: avatar, onTap: { profilePubkey = $0 })
                    .aspectRatio(TrustWebGraph.aspect, contentMode: .fit)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(TrustPathText.label(path, name: name)))

                Text(TrustPathText.label(path, name: name))
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)

                if !path.bridges.isEmpty { bridgeList }

                Text(footnote)
                    .font(.appSystem(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .background(Color.platformControlBackground)
        .navigationTitle("Web of Trust")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            nostrService.fetchMissingProfiles(for: [me, author] + path.bridges)
            if Motion.isReduced {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 0.8)) { progress = 1 }
            }
        }
        .sheet(item: Binding<IdentifiableString?>(
            get: { profilePubkey.map { IdentifiableString(id: $0) } },
            set: { profilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { profilePubkey = nil })
        }
    }

    private var bridgeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(path.reach == .follow ? "ALSO FOLLOWED BY" : "FOLLOWED BY")
                .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(0.5)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(path.bridges.enumerated()), id: \.element) { index, pubkey in
                    if index > 0 { Divider().padding(.leading, 52) }
                    Button { profilePubkey = pubkey } label: {
                        HStack(spacing: 12) {
                            avatar(pubkey, 28)
                            Text(name(pubkey))
                                .font(.appSystem(size: 14))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.appSystem(size: 11, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(name(pubkey)))
                    .accessibilityHint(Text("Opens their profile"))
                }
            }
            .background(Color.platformTertiaryGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var footnote: String {
        switch path.reach {
        case .web:
            return "They're in your Web of Trust through people further out. The follow lists checked didn't show who links you."
        case .outside:
            return "Only as sure as the relays asked. A follow list they don't hold can't be seen."
        case .unknown:
            return "Your trust graph hasn't loaded yet. Open this again in a moment."
        default:
            return path.hasMore
                ? "Showing \(path.bridges.count) of the people you follow who follow them, from their public follow lists."
                : "From the public follow lists of people you follow."
        }
    }

    private func avatar(_ pubkey: String, _ size: CGFloat) -> AnyView {
        AnyView(AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size))
    }

    private func name(_ pubkey: String) -> String {
        nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }
}

/// The constellation itself. Layout is pure geometry from the view's size:
/// you sit left of centre inside the ring, the author out at the right edge,
/// and slot angles alternate either side of the author's direction
/// (0°, +a, −a, +2a, …).
private struct TrustWebGraph: View {
    let me: String
    let author: String
    let path: TrustPath
    let progress: CGFloat
    let avatar: (String, CGFloat) -> AnyView
    let onTap: (String) -> Void

    /// Faint dots standing in for the rest of your follows: one every 12°.
    private static let ghostStep = 12.0
    /// Wider than tall, so the lines from the ring out to the author have room.
    static let aspect: CGFloat = 1.35

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(size: geo.size, path: path)
            let purple = Color.havenPurple

            ZStack {
                // Your follows: one faint circle plus static dots, a few shapes total.
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    .frame(width: layout.ringR * 2, height: layout.ringR * 2)
                    .position(layout.center)
                layout.ghostDots(step: Self.ghostStep)
                    .fill(Color.secondary.opacity(0.28))

                // Lines. Lit ones trim in together, once.
                if let dim = layout.dimPath {
                    dim.trim(from: 0, to: progress)
                        .stroke(Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 5]))
                }
                if let lit = layout.litPath {
                    lit.trim(from: 0, to: progress)
                        .stroke(purple, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round,
                                                           dash: path.reach == .web ? [4, 5] : []))
                        .shadow(color: purple.opacity(0.55), radius: 4)
                }

                // Nodes.
                if let more = layout.moreSlot {
                    Text("+")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: layout.bridgeSize * 0.8, height: layout.bridgeSize * 0.8)
                        .background(Circle().fill(Color.platformTertiaryGroupedBackground))
                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                        .position(more)
                }
                ForEach(Array(zip(path.bridges, layout.bridgeSlots)), id: \.0) { pubkey, point in
                    node(pubkey, size: layout.bridgeSize, ring: purple)
                        .position(point)
                }
                if path.reach != .you {
                    node(author, size: layout.endSize,
                         ring: path.reach == .outside || path.reach == .unknown ? Color.secondary.opacity(0.4) : purple)
                        .position(layout.authorPoint)
                }
                avatar(me, layout.endSize)
                    .overlay(Circle().stroke(purple, lineWidth: 2))
                    .position(layout.center)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func node(_ pubkey: String, size: CGFloat, ring: Color) -> some View {
        Button { onTap(pubkey) } label: {
            avatar(pubkey, size)
                .overlay(Circle().stroke(ring, lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Where everything sits for a given square side. Built once per render,
    /// no iteration: each node is one cos/sin.
    struct Layout {
        let center: CGPoint
        let ringR: CGFloat
        let bridgeSize: CGFloat
        let endSize: CGFloat
        let authorPoint: CGPoint
        let bridgeSlots: [CGPoint]
        let moreSlot: CGPoint?
        let litPath: Path?
        let dimPath: Path?
        private let occupied: [Double]

        init(size: CGSize, path: TrustPath) {
            let h = size.height
            ringR = min(h * 0.36, size.width * 0.27)
            center = CGPoint(x: max(ringR + 8, size.width * 0.36), y: h / 2)
            bridgeSize = max(26, h * 0.11)
            endSize = max(34, h * 0.14)
            let outerR = size.width - endSize / 2 - 4 - center.x
            let center = self.center
            let ringR = self.ringR

            func point(_ degrees: Double, _ r: CGFloat) -> CGPoint {
                let rad = degrees * .pi / 180
                return CGPoint(x: center.x + r * CGFloat(cos(rad)), y: center.y + r * CGFloat(sin(rad)))
            }
            // Spaced so neighbouring avatars on the ring don't overlap.
            let spacing = max(26, Double(bridgeSize * 1.3 / ringR) * 180 / .pi)
            // 0, +1, −1, +2, −2 … steps out from the author's direction.
            func slotAngle(_ i: Int) -> Double {
                let k = Double((i + 1) / 2)
                return i % 2 == 1 ? k * spacing : -k * spacing
            }

            // When you follow them, the author sits on the ring at slot 0 and
            // bridges fan out either side of it. Otherwise the bridges (and
            // the "+" for more) are spread evenly across the author's side.
            let onRing = path.reach == .follow
            let count = path.bridges.count + (path.hasMore ? 1 : 0)
            let slots: [Double] = onRing
                ? (0..<count).map { slotAngle($0 + 1) }
                : (0..<count).map { (Double($0) - Double(count - 1) / 2) * spacing }
            let angles = Array(slots.prefix(path.bridges.count))
            bridgeSlots = angles.map { point($0, ringR) }
            let moreAngle = path.hasMore ? slots.last : nil
            moreSlot = moreAngle.map { point($0, ringR) }
            authorPoint = path.reach == .you ? center : point(0, onRing ? ringR : outerR)
            occupied = angles + [moreAngle, onRing ? 0 : nil].compactMap { $0 }

            switch path.reach {
            case .follow:
                var p = Path()
                p.move(to: center); p.addLine(to: authorPoint)
                for b in bridgeSlots { p.move(to: center); p.addLine(to: b) }
                litPath = p; dimPath = nil
            case .bridged:
                var p = Path()
                for b in bridgeSlots { p.move(to: center); p.addLine(to: b); p.addLine(to: authorPoint) }
                litPath = p; dimPath = nil
            case .web:
                var p = Path()
                p.move(to: center); p.addLine(to: authorPoint)
                litPath = p; dimPath = nil
            case .outside:
                // Breaks off just past your follows, short of the author.
                var p = Path()
                p.move(to: center); p.addLine(to: point(0, ringR + bridgeSize * 0.4))
                litPath = nil; dimPath = p
            case .you, .unknown:
                litPath = nil; dimPath = nil
            }
        }

        /// The rest of your follows as small dots on the ring, leaving gaps
        /// where a real node sits.
        func ghostDots(step: Double) -> Path {
            var p = Path()
            let gap = Double(bridgeSize / ringR) * 180 / .pi * 0.75
            var a = 0.0
            while a < 360 {
                let clear = occupied.allSatisfy { abs(Self.wrap(a - $0)) > gap }
                if clear {
                    let rad = a * .pi / 180
                    let x = center.x + ringR * CGFloat(cos(rad)), y = center.y + ringR * CGFloat(sin(rad))
                    p.addEllipse(in: CGRect(x: x - 2, y: y - 2, width: 4, height: 4))
                }
                a += step
            }
            return p
        }

        private static func wrap(_ d: Double) -> Double {
            var d = d.truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            return d
        }
    }
}

/// The one-line summary shared by the card and the expanded view.
enum TrustPathText {
    static func label(_ path: TrustPath?, name: (String) -> String) -> String {
        guard let path else { return "Tracing how they reach you…" }
        switch path.reach {
        case .you:
            return "This is you."
        case .follow:
            return path.bridges.isEmpty
                ? "You follow them · 1 hop"
                : "You follow them · also followed by \(bridgeNames(path, name: name))"
        case .bridged:
            return "Followed by \(bridgeNames(path, name: name)) you follow · 2 hops"
        case .web:
            return "In your Web of Trust"
        case .outside:
            return "Not in your web · no one you follow follows them"
        case .unknown:
            return "Your trust graph isn't loaded yet"
        }
    }

    private static func bridgeNames(_ path: TrustPath, name: (String) -> String) -> String {
        let names = path.bridges.prefix(2).map(name)
        let rest = path.bridges.count - names.count
        if rest > 0 || path.hasMore { return names.joined(separator: ", ") + " + more" }
        return names.joined(separator: " and ")
    }
}
