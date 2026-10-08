import SwiftUI

/// The Trust Path card opened up into a map. Someone sits in the middle (you,
/// at first) with every person they follow as a dot on a ring around them,
/// and the author past it. Dots that follow the author light up. Each dot's
/// spot comes from its key (`TrustMap.angle`), so nothing is ever laid out
/// twice: pinching and panning only move the camera, and re-centering on
/// someone swaps the ring for theirs.
struct TrustWebView: View {
    let author: String
    let path: TrustPath
    @EnvironmentObject var nostrService: NostrService

    /// One map: who is in the middle and what we know about their follows.
    struct Frame {
        let center: String
        /// Everyone `center` follows: the dots on the ring.
        let ring: [String]
        /// False when no relay had `center`'s follow list, so the empty ring
        /// means "unknown", not "follows no one".
        var listFound = true
        let path: TrustPath
        /// Every bridge found so far, sorted; starts as the card's 5.
        var bridges: [String]
        /// Signers whose lists already came back, so a batch skips them.
        var seen: Set<String>
        /// No relay had any more lists that tag the author.
        var exhausted = false
        /// 3-hop routes once "look deeper" ran; nil before.
        var chains: [TrustMap.Chain]?
    }

    @State private var crumbs: [String] = []
    @State private var frames: [String: Frame] = [:]
    /// nil until picked: then each frame opens on its own shortest reach.
    @State private var pickedHops: Int?
    @State private var camera = TrustMapCamera()
    @State private var peek: String?
    @State private var loadingMore = false
    @State private var lookingDeeper = false
    @State private var profilePubkey: String?
    @State private var showingList = false

    private var me: String { ConfigService.shared.activeAccountHexPubkey }
    private var centerKey: String { crumbs.last ?? me }
    private var frame: Frame? { frames[centerKey] }

    private var hops: Int {
        if let pickedHops { return pickedHops }
        return frame?.path.reach == .follow ? 1 : 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    if let frame {
                        TrustMapCanvas(frame: frame, me: me, author: author, hops: hops,
                                       myFollows: Set(FeedService.shared.followedPubkeys),
                                       size: geo.size, camera: $camera,
                                       avatar: avatar, name: name,
                                       onTap: tapped, onPeek: { peek = $0 },
                                       onFaces: { nostrService.fetchMissingProfiles(for: $0) })
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if camera.scale > 1.05 {
                        Text(String(format: "%.1f×", camera.scale))
                            .font(.appSystem(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(10)
                            .accessibilityHidden(true)
                    }
                    if let peek { peekCard(peek) }
                }
                .clipped()
            }
            footer
        }
        .background(Color.platformControlBackground)
        .navigationTitle(centerKey == me ? "Web of Trust" : name(centerKey))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingList = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel(Text("People on this map"))
            }
        }
        .onAppear {
            guard frames[me] == nil else { return }
            crumbs = [me]
            frames[me] = Frame(center: me, ring: FeedService.shared.followedPubkeys, path: path,
                               bridges: path.bridges, seen: Set(path.bridges))
            nostrService.fetchMissingProfiles(for: [me, author] + path.bridges)
        }
        .onChange(of: pickedHops) { _, hops in
            if hops == 3, frame?.chains == nil { lookDeeper() }
        }
        .sheet(isPresented: $showingList) { peopleList }
        .sheet(item: Binding<IdentifiableString?>(
            get: { profilePubkey.map { IdentifiableString(id: $0) } },
            set: { profilePubkey = $0?.id }
        )) { p in
            ProfileView(pubkey: p.id, onDismiss: { profilePubkey = nil })
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(crumbs.enumerated()), id: \.element) { index, pubkey in
                        if index > 0 { crumbArrow }
                        Button { jump(to: index) } label: { chip(pubkey, on: index == crumbs.count - 1) }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text(index == crumbs.count - 1 ? "" : "Goes back to this step"))
                    }
                    if centerKey != author {
                        crumbArrow
                        chip(author, on: false, destination: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Looking for \(name(author))"))
                    }
                }
                .padding(.horizontal)
            }

            Picker("Hops", selection: Binding(get: { hops }, set: { pickedHops = $0 })) {
                Text("1 hop").tag(1)
                Text("2 hops").tag(2)
                Text("3 hops").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)

            explainer
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var crumbArrow: some View {
        Text("›").font(.appSystem(size: 13)).foregroundColor(.secondary).accessibilityHidden(true)
    }

    private func chip(_ pubkey: String, on: Bool, destination: Bool = false) -> some View {
        HStack(spacing: 6) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 22)
            Text(name(pubkey))
                .font(.appSystem(size: 13))
                .lineLimit(1)
        }
        .padding(.leading, 3)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .foregroundColor(destination ? Color.havenPurple : .primary)
        .background(Capsule().fill(on ? Color.havenPurple.opacity(0.18) : Color.platformTertiaryGroupedBackground))
        .overlay(Capsule().stroke(destination ? Color.havenPurple.opacity(0.5) : .clear, lineWidth: 1))
    }

    @ViewBuilder private var explainer: some View {
        if let frame {
            let them = name(author)
            let center = frame.center == me ? nil : name(frame.center)
            let count = Text("\(frame.bridges.count)\(frame.exhausted ? "" : "+")")
                .foregroundColor(.havenPurple).bold()
            if !frame.listFound {
                Text("No relay checked had \(name(frame.center))'s follow list, so their ring can't be drawn.")
            } else if hops == 3 {
                if lookingDeeper {
                    Text("Looking two steps further out. This downloads a few MB of follow lists.")
                } else if let chains = frame.chains, !chains.isEmpty {
                    let via = Text("\(Set(chains.map(\.via)).count)").foregroundColor(.havenPurple).bold()
                    Text("\(via) people who follow \(them) are followed by \(center.map { "people \($0) follows" } ?? "people you follow") · 3 hops.")
                } else if frame.chains != nil {
                    Text("No 3-hop route turned up in the follow lists checked.")
                } else {
                    Text("Looking deeper: two steps further out.")
                }
            } else if frame.center == author {
                Text("Everyone \(them) follows. Tap a face to see their path.")
            } else if frame.ring.contains(author), hops == 1 {
                Text("\(center ?? "You") \(center == nil ? "follow" : "follows") \(them) directly · 1 hop.")
            } else if !frame.bridges.isEmpty, hops == 2 {
                if let center {
                    let mutual = Text("\(mutualCount(frame))").foregroundColor(.primary).bold()
                    Text("\(center) reaches \(them) through \(count) of their follows · 2 hops. \(mutual) of \(center)'s follows are people you follow too (bright dots).")
                } else {
                    Text("Followed by \(count) people you follow · 2 hops. Pinch to zoom, tap a face to follow their path.")
                }
            } else if frame.ring.contains(author) {
                Text("\(center ?? "You") \(center == nil ? "follow" : "follows") \(them) directly. Switch to 2 hops to see who else does.")
            } else {
                switch frame.path.reach {
                case .web: Text("In your Web of Trust through people further out. 3 hops looks deeper.")
                case .outside: Text("Not in your web. No one you follow follows them, in the lists checked.")
                case .unknown where center != nil:
                    Text("None of \(center ?? "")'s follows that were checked follow \(them). 3 hops looks deeper.")
                case .unknown: Text("Your trust graph hasn't loaded yet.")
                default: Text("Pinch to zoom, tap a face to follow their path.")
                }
            }
        } else {
            Text("Loading who \(name(centerKey)) follows…")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let frame, frame.listFound {
                HStack(spacing: 6) {
                    legendDot(Color.secondary)
                    Text("\(frame.ring.count.formatted()) \(frame.center == me ? "you follow" : "\(name(frame.center)) follows")")
                    Spacer(minLength: 8)
                    if !frame.bridges.isEmpty, hops >= 2 {
                        legendDot(.havenPurple)
                        Text("\(frame.bridges.count)\(frame.exhausted ? "" : "+") follow \(name(author))")
                            .foregroundColor(.havenPurple)
                    }
                }
                .font(.appSystem(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

                if canLoadMore(frame) {
                    Button(action: showEveryone) {
                        HStack(spacing: 8) {
                            if loadingMore { ProgressView().controlSize(.small) }
                            Text(loadingMore ? "Finding more… \(frame.bridges.count) so far"
                                             : "Show everyone who follows \(name(author))")
                                .lineLimit(1)
                        }
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.platformTertiaryGroupedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingMore)
                }
            }
            if centerKey != me {
                Button { profilePubkey = centerKey } label: {
                    Text("View \(name(centerKey))'s profile")
                        .lineLimit(1)
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.havenPurple)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func legendDot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }

    // MARK: - Peek

    private func peekCard(_ pubkey: String) -> some View {
        let follows = Set(FeedService.shared.followedPubkeys)
        let followsAuthor = frame?.bridges.contains(pubkey) == true
            || frame?.chains?.contains { $0.via == pubkey } == true
        let line = [
            pubkey == me ? "You" : follows.contains(pubkey) ? "You follow" : "Not someone you follow",
            pubkey == author ? nil : followsAuthor ? "follows \(name(author))" : "not seen following \(name(author))",
        ].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name(pubkey)).font(.appSystem(size: 14, weight: .semibold)).lineLimit(1)
                Text(line).font(.appSystem(size: 11)).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button("Profile") { profilePubkey = pubkey; peek = nil }
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.havenPurple)
                .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.platformTertiaryGroupedBackground))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .padding(12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - People list (VoiceOver, and anyone who'd rather read)

    private var peopleList: some View {
        NavigationStack {
            List {
                if let frame {
                    if !frame.bridges.isEmpty {
                        Section(frame.center == me ? "People you follow who follow \(name(author))"
                                                   : "\(name(frame.center))'s follows who follow \(name(author))") {
                            ForEach(frame.bridges, id: \.self) { personRow($0) }
                        }
                    }
                    if let chains = frame.chains, !chains.isEmpty {
                        Section("3 hops") {
                            ForEach(Array(chains.prefix(50).enumerated()), id: \.offset) { _, chain in
                                Button { showingList = false; profilePubkey = chain.via } label: {
                                    Text("\(name(chain.bridge)) → \(name(chain.via)) → \(name(author))")
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }
                    if frame.bridges.isEmpty && (frame.chains ?? []).isEmpty {
                        Text("No one on this map follows \(name(author)) yet.").foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(name(centerKey))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingList = false } }
            }
        }
    }

    private func personRow(_ pubkey: String) -> some View {
        Button { showingList = false; profilePubkey = pubkey } label: {
            HStack(spacing: 12) {
                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 28)
                Text(name(pubkey)).foregroundColor(.primary).lineLimit(1)
            }
        }
        .accessibilityHint(Text("Opens their profile"))
    }

    // MARK: - Actions

    private func tapped(_ pubkey: String) {
        if peek != nil { peek = nil; return }
        guard pubkey != centerKey else { return }
        if let index = crumbs.firstIndex(of: pubkey) { return jump(to: index) }
        crumbs.append(pubkey)
        recenter()
        guard frames[pubkey] == nil else { return }
        Task {
            let list = await TrustPathService.shared.followList(of: pubkey)
            let ring = list ?? []
            let found = await TrustPathService.shared.path(for: author, from: pubkey, follows: ring)
            frames[pubkey] = Frame(center: pubkey, ring: ring, listFound: list != nil, path: found,
                                   bridges: found.bridges, seen: Set(found.bridges))
            nostrService.fetchMissingProfiles(for: [pubkey] + found.bridges)
            if hops == 3, centerKey == pubkey { lookDeeper() }
        }
    }

    private func jump(to index: Int) {
        guard index < crumbs.count - 1 else { return }
        peek = nil
        crumbs = Array(crumbs.prefix(index + 1))
        recenter()
    }

    private func recenter() {
        // 3 hops is a download; don't carry it onto the next person.
        if pickedHops == 3 { pickedHops = nil }
        if Motion.isReduced {
            camera = TrustMapCamera()
        } else {
            withAnimation(.smooth(duration: 0.35)) { camera = TrustMapCamera() }
        }
    }

    /// "Show everyone": batches of 20 lists until no relay has more, lighting
    /// dots as each batch lands. Stops at `TrustMap.maxBatchedLists` a tap.
    private func showEveryone() {
        guard let start = frame, !loadingMore else { return }
        let key = start.center
        loadingMore = true
        Task {
            var fetched = 0
            while let current = frames[key], !current.exhausted, fetched < TrustMap.maxBatchedLists {
                let lists = await TrustPathService.shared.moreBridgeLists(author: author, follows: current.ring,
                                                                          seen: current.seen)
                guard var updated = frames[key] else { break }
                fetched += lists.count
                let fresh = TrustPath.allBridges(author: author, me: key, follows: Set(current.ring),
                                                 contactLists: lists)
                updated.seen.formUnion(lists.compactMap { $0["pubkey"] as? String })
                updated.bridges = Array(Set(updated.bridges).union(fresh)).sorted()
                if lists.isEmpty { updated.exhausted = true }
                frames[key] = updated
            }
            if let lit = frames[key]?.bridges {
                nostrService.fetchMissingProfiles(for: TrustMap.spread(lit, count: TrustMapCanvas.maxFaces))
            }
            loadingMore = false
        }
    }

    private func lookDeeper() {
        guard let start = frame, !lookingDeeper else { return }
        let key = start.center
        lookingDeeper = true
        Task {
            let graph = key == me ? FeedService.shared.relayTabTrustedPubkeys() : []
            let chains = await TrustPathService.shared.deeperChains(author: author, center: key,
                                                                    follows: start.ring, trustGraph: graph)
            frames[key]?.chains = chains
            nostrService.fetchMissingProfiles(
                for: chains.prefix(TrustMap.shownChains).flatMap { [$0.bridge, $0.via] })
            lookingDeeper = false
        }
    }

    // MARK: - Helpers

    private func canLoadMore(_ frame: Frame) -> Bool {
        hops >= 2 && !frame.exhausted && !frame.bridges.isEmpty
            && (frame.path.hasMore || frame.bridges.count > TrustPath.shownBridges)
    }

    private func mutualCount(_ frame: Frame) -> Int {
        let mine = Set(FeedService.shared.followedPubkeys)
        return frame.ring.filter(mine.contains).count
    }

    private func avatar(_ pubkey: String, _ size: CGFloat) -> AnyView {
        AnyView(AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size))
    }

    private func name(_ pubkey: String) -> String {
        if pubkey == me { return "You" }
        return nostrService.profiles[pubkey]?.bestName ?? "npub…" + String(pubkey.suffix(6))
    }
}

/// Zoom and pan. Scale 1 fits the ring; the layout itself never changes.
struct TrustMapCamera: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
}

/// The map itself: one Canvas for the ring, dots and lines, plus a few dozen
/// face views on top. World units: the ring has radius 1 around the centre.
struct TrustMapCanvas: View {
    let frame: TrustWebView.Frame
    let me: String
    let author: String
    let hops: Int
    let myFollows: Set<String>
    let size: CGSize
    @Binding var camera: TrustMapCamera
    let avatar: (String, CGFloat) -> AnyView
    let name: (String) -> String
    let onTap: (String) -> Void
    let onPeek: (String) -> Void
    /// The faces on screen after a gesture, so their pictures can load.
    let onFaces: ([String]) -> Void

    /// Lit people drawn as faces; the rest stay orange dots.
    static let maxFaces = 12
    /// Extra faces when zoomed in on part of the ring.
    private static let maxZoomFaces = 40
    private static let zoomFacesAt: CGFloat = 3.5
    private static let namesAt: CGFloat = 1.8
    private static let outerR = 1.45
    /// How far a dot may sit in or out of the ring. Wide enough that, zoomed
    /// all the way in, a thousand follows have room for a face and a name each.
    private static let bandWidth = 0.08
    private static let maxScale: CGFloat = 16
    private static let viaR = 1.24

    @State private var pinching = false
    @State private var pinchStart = TrustMapCamera()
    @State private var lastDrag: CGSize = .zero

    private var baseR: CGFloat { min(size.width, size.height) / 2 / 1.62 }

    struct Face {
        let pubkey: String
        let size: CGFloat
        let ring: Color
        let lit: Bool
        let label: Bool
    }

    // MARK: World layout (fixed)

    private func polar(_ degrees: Double, _ r: Double) -> CGPoint {
        let rad = (degrees - 90) * .pi / 180
        return CGPoint(x: r * cos(rad), y: r * sin(rad))
    }

    private func dot(_ pubkey: String) -> CGPoint {
        polar(TrustMap.angle(of: pubkey), 1 + Self.bandWidth * TrustMap.band(of: pubkey))
    }

    private func world(_ pubkey: String, ring: Set<String>) -> CGPoint {
        if pubkey == frame.center { return .zero }
        if ring.contains(pubkey) { return dot(pubkey) }
        if pubkey == author || pubkey == me { return polar(TrustMap.angle(of: pubkey), Self.outerR) }
        return polar(TrustMap.angle(of: pubkey), Self.viaR)
    }

    private func screen(_ p: CGPoint) -> CGPoint {
        let k = baseR * camera.scale
        return CGPoint(x: size.width / 2 + camera.offset.width + p.x * k,
                       y: size.height / 2 + camera.offset.height + p.y * k)
    }

    // MARK: What is lit at this hop count

    private var litBridges: [String] { hops >= 2 ? frame.bridges : [] }
    private var chains: [TrustMap.Chain] { hops == 3 ? (frame.chains ?? []) : [] }

    /// Everyone drawn as a face besides the centre, most important first.
    /// A face only goes where it doesn't cover one already placed; whoever
    /// doesn't fit stays a dot until zooming makes room.
    private func faces(ring: Set<String>) -> [Face] {
        var out: [Face] = []
        var placed: Set<String> = [frame.center]
        var taken: [(point: CGPoint, half: CGSize)] = [(screen(.zero), CGSize(width: 30, height: 34))]
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -12, dy: -12)
        func add(_ pubkey: String, _ size: CGFloat, _ color: Color, lit: Bool, label: Bool, always: Bool = false) {
            guard !placed.contains(pubkey) else { return }
            let point = screen(world(pubkey, ring: ring))
            // Half the box the face (and its name, which hangs below) needs.
            let half = CGSize(width: label ? max(size / 2, 26) : size / 2 + 2,
                              height: label ? size / 2 + 9 : size / 2 + 2)
            if !always {
                guard bounds.contains(point) else { return }
                let clear = taken.allSatisfy { other in
                    abs(other.point.x - point.x) >= other.half.width + half.width
                        || abs(other.point.y - point.y) >= other.half.height + half.height
                }
                guard clear else { return }
            }
            placed.insert(pubkey)
            taken.append((point, half))
            out.append(Face(pubkey: pubkey, size: size, ring: color, lit: lit, label: label))
        }
        let grow = min(1.5, sqrt(camera.scale))
        let named = camera.scale >= Self.namesAt
        if frame.center != author { add(author, 38, .havenPurple, lit: true, label: true, always: true) }
        if frame.center != me { add(me, 28, .secondary, lit: false, label: true, always: true) }
        for pubkey in TrustMap.spread(litBridges, count: Self.maxFaces) {
            add(pubkey, 24 * grow, .havenPurple, lit: true, label: named)
        }
        for chain in chains.prefix(TrustMap.shownChains) {
            add(chain.via, 22 * grow, .havenPurple, lit: true, label: named)
            add(chain.bridge, 22 * grow, .havenPurple, lit: true, label: named)
        }
        if camera.scale >= Self.zoomFacesAt {
            let lit = Set(litBridges)
            let before = out.count
            // Lit people first, so a zoomed arc names who matters before
            // everyone else around them.
            for pubkey in frame.ring.filter(lit.contains) + frame.ring.filter({ !lit.contains($0) })
            where out.count - before < Self.maxZoomFaces {
                let isLit = lit.contains(pubkey)
                add(pubkey, 20 * grow, isLit ? .havenPurple : Color.secondary.opacity(0.5), lit: isLit, label: true)
            }
        }
        return out
    }

    var body: some View {
        let ring = Set(frame.ring)
        let faces = self.faces(ring: ring)
        let faceKeys = Set(faces.map(\.pubkey))
        ZStack {
            Canvas { context, _ in draw(in: &context, ring: ring, faces: faceKeys) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ForEach(faces, id: \.pubkey) { face in
                faceView(face.pubkey, size: face.size, ring: face.ring, lit: face.lit, label: face.label)
                    .position(screen(world(face.pubkey, ring: ring)))
            }
            faceView(frame.center, size: 46, ring: frame.center == me ? .primary : .havenPurple,
                     lit: true, label: true)
                .position(screen(.zero))
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { reset() }
        .onTapGesture { onTap(frame.center) }
        .gesture(SimultaneousGesture(magnify, pan))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Web of Trust map"))
        .onAppear { onFaces(faces.map(\.pubkey)) }
    }

    private func faceView(_ pubkey: String, size: CGFloat, ring: Color, lit: Bool, label: Bool) -> some View {
        let main = pubkey == frame.center || pubkey == author
        return VStack(spacing: 3) {
            avatar(pubkey, size)
                .overlay(Circle().stroke(ring, lineWidth: 2))
                .background(Circle().fill(Color.platformControlBackground).padding(-2))
            if label {
                Text(name(pubkey))
                    .font(.appSystem(size: main ? 12 : 10, weight: lit ? .semibold : .regular))
                    .foregroundColor(lit ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                    // Lines run under the labels; a backing keeps names legible.
                    .padding(.horizontal, 4)
                    .background(Capsule().fill(Color.platformControlBackground.opacity(0.75)))
            }
        }
        // Centre the avatar, not avatar + name, on the point.
        .offset(y: label ? (3 + (main ? 15 : 13)) / 2 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onTap(pubkey) }
        .onLongPressGesture(minimumDuration: 0.4) { onPeek(pubkey) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name(pubkey)))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(pubkey == frame.center ? "" : "Moves them to the middle of the map"))
        .accessibilityAction(named: Text("Details")) { onPeek(pubkey) }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, ring: Set<String>, faces: Set<String>) {
        let k = baseR * camera.scale
        let c = screen(.zero)
        let orange = Color.havenPurple
        let authorOnRing = ring.contains(author)

        // The ring as a soft band.
        context.stroke(Path(ellipseIn: CGRect(x: c.x - k, y: c.y - k, width: 2 * k, height: 2 * k)),
                       with: .color(.white.opacity(0.06)), lineWidth: (2 * Self.bandWidth + 0.04) * k)

        let authorPoint = screen(world(author, ring: ring))
        let lit = Set(litBridges)

        // Lines first, under the dots.
        var faint = Path(), strong = Path(), dashed = Path(), grey = Path()
        for pubkey in litBridges {
            let p = screen(world(pubkey, ring: ring))
            if faces.contains(pubkey) {
                strong.move(to: c); strong.addLine(to: p); strong.addLine(to: authorPoint)
            } else {
                faint.move(to: p); faint.addLine(to: authorPoint)
            }
        }
        if authorOnRing, frame.center != author {
            strong.move(to: c); strong.addLine(to: authorPoint)
        }
        for chain in chains {
            let b = screen(world(chain.bridge, ring: ring)), v = screen(world(chain.via, ring: ring))
            if faces.contains(chain.via) {
                dashed.move(to: c); dashed.addLine(to: b); dashed.addLine(to: v); dashed.addLine(to: authorPoint)
            } else {
                faint.move(to: v); faint.addLine(to: authorPoint)
            }
        }
        if frame.center != me {
            grey.move(to: screen(world(me, ring: ring))); grey.addLine(to: c)
        }
        if hops == 2, litBridges.isEmpty, !authorOnRing, frame.center != author {
            switch frame.path.reach {
            case .web:
                dashed.move(to: c); dashed.addLine(to: authorPoint)
            case .outside, .unknown:
                grey.move(to: c); grey.addLine(to: screen(polar(TrustMap.angle(of: author), 1.12)))
            default: break
            }
        }
        context.stroke(faint, with: .color(orange.opacity(0.18)), lineWidth: 1)
        context.stroke(grey, with: .color(.secondary.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4]))
        context.stroke(dashed, with: .color(orange.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [5, 4]))
        context.stroke(strong, with: .color(orange.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        // Dots: three fills for the whole ring, however many people are on it.
        let grow = min(2, sqrt(camera.scale))
        func circle(_ p: CGPoint, _ r: CGFloat) -> CGRect {
            CGRect(x: p.x - r * grow, y: p.y - r * grow, width: 2 * r * grow, height: 2 * r * grow)
        }
        let view = CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8)
        var dim = Path(), bright = Path(), hot = Path()
        let showMutual = frame.center != me
        for pubkey in frame.ring where !faces.contains(pubkey) {
            let p = screen(dot(pubkey))
            guard view.contains(p) else { continue }
            if lit.contains(pubkey) {
                hot.addEllipse(in: circle(p, 2.6))
            } else if showMutual, myFollows.contains(pubkey) {
                bright.addEllipse(in: circle(p, 1.9))
            } else {
                dim.addEllipse(in: circle(p, 1.4))
            }
        }
        for chain in chains where !faces.contains(chain.via) {
            hot.addEllipse(in: circle(screen(world(chain.via, ring: ring)), 2.6))
        }
        context.fill(dim, with: .color(.white.opacity(0.28)))
        context.fill(bright, with: .color(.white.opacity(0.7)))
        context.fill(hot, with: .color(orange))
    }

    // MARK: Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !pinching { pinching = true; pinchStart = camera }
                let scale = min(Self.maxScale, max(1, pinchStart.scale * value.magnification))
                let k = scale / pinchStart.scale
                // Zoom about the pinch point, not the middle of the view.
                let ax = value.startAnchor.x * size.width - size.width / 2
                let ay = value.startAnchor.y * size.height - size.height / 2
                camera = TrustMapCamera(scale: scale,
                                        offset: CGSize(width: ax + (pinchStart.offset.width - ax) * k,
                                                       height: ay + (pinchStart.offset.height - ay) * k))
            }
            .onEnded { _ in
                pinching = false
                settle()
            }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width,
                                   height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                guard !pinching else { return }
                camera.offset.width += delta.width
                camera.offset.height += delta.height
            }
            .onEnded { _ in
                lastDrag = .zero
                settle()
            }
    }

    /// After a gesture: keep some of the ring on screen however far it was
    /// dragged, and load pictures for whoever became a face.
    private func settle() {
        let limit = baseR * camera.scale * 1.5
        let clamped = CGSize(width: min(limit, max(-limit, camera.offset.width)),
                             height: min(limit, max(-limit, camera.offset.height)))
        if clamped != camera.offset {
            withAnimation(Motion.isReduced ? nil : .smooth(duration: 0.25)) { camera.offset = clamped }
        }
        onFaces(faces(ring: Set(frame.ring)).map(\.pubkey))
    }

    private func reset() {
        withAnimation(Motion.isReduced ? nil : .smooth(duration: 0.35)) { camera = TrustMapCamera() }
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
