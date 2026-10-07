import SwiftUI

/// The "Fill your feed" guide, drawn over the feed: its cards, the meter
/// above the tab bar, and the sheets they open. What shows comes from
/// `FillYourVaultCoordinator.phase`; the rules are in `FillYourFeedGuide`.
/// Design: OUTBOX/fill-your-vault-mockup.html (Tory).
struct FillYourFeedOverlay: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared
    @ObservedObject private var nostr = NostrService.shared
    @ObservedObject private var buttonRow = FloatingButtonRow.shared
    @Environment(\.floatingTabBarHeight) private var tabBarHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showingPicks = false
    @State private var boltProgress: CGFloat = -0.2
    @State private var boltRunning = false

    private var compactText: Bool {
        dynamicTypeSize.isAccessibilitySize || ConfigService.shared.config.textSizeScale >= 1.3
    }

    var body: some View {
        ZStack {
            if dims {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            card
                .frame(maxWidth: 420)
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: cardAlignment)
                .padding(.top, 12)
                .padding(.bottom, tabBarHeight + 90)
            if guide.meterShowing {
                meterArea
                    .padding(.horizontal, 16)
                    // On Post's row: Post rises above the open meter, and the
                    // pill sits beside Post on the leading edge.
                    .padding(.bottom, tabBarHeight > 0 ? buttonRow.buttonBottom : 20)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: guide.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: guide.meterCollapsed)
        .sheet(item: profileCardBinding) { item in
            FeedProfileCard(pubkey: item.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPicks) {
            FeedPicksSheet(onHide: {
                showingPicks = false
                guide.closeGuide()
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: guide.celebrateVaultMaster) { _, celebrate in
            if celebrate { playBolt() }
        }
        .onAppear {
            if guide.celebrateVaultMaster { playBolt() }
        }
    }

    /// Intro, "ready" and the web of trust (10 follows) sit over a dimmed feed; the topic
    /// picker and the hint leave the feed in view.
    private var dims: Bool { [.intro, .ready, .master].contains(guide.phase) }

    private var cardAlignment: Alignment { guide.phase == .hint ? .top : .center }

    private var profileCardBinding: Binding<IdentifiableString?> {
        Binding(
            get: { guide.profileCardPubkey.map { IdentifiableString(id: $0) } },
            set: { guide.profileCardPubkey = $0?.id }
        )
    }

    @ViewBuilder
    private var card: some View {
        switch guide.phase {
        case .intro: IntroCard()
        case .topics: TopicsCard()
        case .hint: HintCard()
        case .ready: ReadyCard()
        case .master: MasterCard()
        case .off, .browsing: EmptyView()
        }
    }

    // MARK: Meter

    private var gold: Bool { guide.meter.stage == .master }

    @ViewBuilder
    private var meterArea: some View {
        if guide.meterCollapsed {
            HStack {
                pill
                Spacer()
            }
            .onAppear { guide.meterHeight = 0 }
        } else {
            meterBar
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { guide.meterHeight = $0 }
        }
    }

    private var meterBar: some View {
        HStack(spacing: 12) {
            slots
            VStack(alignment: .leading, spacing: 1) {
                Text(FillYourFeedGuide.meterTitle(guide.meter, compact: compactText))
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(gold ? Gold.light : .white)
                if !compactText {
                    Text(FillYourFeedGuide.meterSubtitle(guide.meter))
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                guide.meterCollapsed = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fold the meter down")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(meterBackground(cornerRadius: 26))
        .overlay(boltLayer.clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { showingPicks = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(guide.meter.accessibilityText)
        .accessibilityHint("Opens your picks.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Fold the meter down") { guide.meterCollapsed = true }
    }

    private var slots: some View {
        let row = guide.meter.slots
        let size: CGFloat = row > VaultMeter.goal ? 24 : 32
        let people = guide.meter.recent.suffix(row)
        return HStack(spacing: row > VaultMeter.goal ? -8 : -6) {
            ForEach(0..<row, id: \.self) { index in
                if index < people.count {
                    let pubkey = Array(people)[index]
                    AvatarView(url: nostr.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: size)
                        .overlay(Circle().stroke(gold ? Gold.mid : Color(white: 0.08), lineWidth: 2))
                        .shadow(color: gold ? Gold.mid.opacity(0.6) : .clear, radius: 4)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                } else {
                    // A ring in the meter's colour, like the photos', so
                    // overlapping slots don't cross their dashes.
                    Circle()
                        .fill(Color(white: 0.12))
                        .overlay(
                            Circle()
                                .inset(by: 2)
                                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                                .foregroundColor(.white.opacity(0.35))
                        )
                        .overlay(Circle().stroke(Color(white: 0.08), lineWidth: 2))
                        .frame(width: size, height: size)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6), value: guide.meter.recent)
        .accessibilityHidden(true)
    }

    private var pill: some View {
        Button {
            guide.meterCollapsed = false
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: FillYourFeedGuide.ringFraction(guide.meter))
                        .stroke(gold ? Gold.mid : Color.havenPurple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(gold ? Gold.mid : .havenPurple)
                }
                .frame(width: 26, height: 26)
                Text(FillYourFeedGuide.pillText(guide.meter))
                    .font(.appSubheadline.weight(.semibold))
                    .foregroundColor(gold ? Gold.light : .white)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(minHeight: 44)
            .background(meterBackground(cornerRadius: 22))
            .overlay(boltLayer.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(guide.meter.accessibilityText)
        .accessibilityHint("Opens the meter.")
    }

    private func meterBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(gold ? Gold.mid.opacity(0.75) : Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: gold ? Gold.mid.opacity(0.35) : .black.opacity(0.3), radius: gold ? 12 : 8)
    }

    /// The zap: a bolt crossing the meter, then a flash. Drawn over the
    /// meter only while it runs.
    @ViewBuilder
    private var boltLayer: some View {
        if boltRunning {
            GeometryReader { proxy in
                ZStack {
                    RadialGradient(colors: [Gold.light.opacity(0.55), .clear], center: .center,
                                   startRadius: 0, endRadius: proxy.size.width * 0.6)
                        .opacity(boltProgress > 0.6 ? Double(1.2 - boltProgress) * 1.5 : 0)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 30, weight: .black))
                        .foregroundColor(Gold.light)
                        .shadow(color: Gold.mid, radius: 6)
                        .shadow(color: Gold.mid, radius: 14)
                        .rotationEffect(.degrees(90))
                        .position(x: proxy.size.width * boltProgress, y: proxy.size.height / 2)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func playBolt() {
        guide.meterCollapsed = false
        if reduceMotion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { guide.showMasterCard() }
            return
        }
        boltProgress = -0.2
        boltRunning = true
        withAnimation(.timingCurve(0.5, 0, 0.3, 1, duration: 0.9)) { boltProgress = 1.2 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { boltRunning = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { guide.showMasterCard() }
    }
}

enum Gold {
    static let light = Color(red: 1.0, green: 0.878, blue: 0.541)
    static let mid = Color(red: 0.949, green: 0.722, blue: 0.122)
    static let dark = Color(red: 0.788, green: 0.541, blue: 0.0)
}

// MARK: - Card chrome

/// Ted's tutorial card look (TutorialStage), shared by the guide's cards.
private struct GuideCard<Content: View>: View {
    var step: Int? = nil
    var border: Color = .havenPurple
    var onSkip: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if step != nil || onSkip != nil {
                HStack {
                    if let step {
                        Text("\(step) of 3")
                            .font(.appCaption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let onSkip {
                        Button("Skip", action: onSkip)
                            .font(.appCaption.weight(.semibold))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 44, minHeight: 32)
                            .accessibilityHint(Text("Closes this guide. Replay it from Settings, Tutorials."))
                    }
                }
            }
            content
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.12))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(border.opacity(0.6), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct PrimaryButton: View {
    let title: String
    var wide = false
    var disabled = false
    var fill: AnyShapeStyle = AnyShapeStyle(Color.havenPurple)
    var textColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.appBody.weight(.semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 20)
                .frame(maxWidth: wide ? .infinity : nil, minHeight: 44)
                .background(Capsule().fill(fill))
                .opacity(disabled ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

@MainActor private func title(_ text: String) -> some View {
    Text(text)
        .font(.appTitle3.weight(.bold))
        .foregroundColor(.white)
        .accessibilityAddTraits(.isHeader)
}

@MainActor private func bodyText(_ text: String) -> some View {
    Text(text)
        .font(.appSubheadline)
        .foregroundColor(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - 1. Intro

private struct IntroCard: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared

    var body: some View {
        GuideCard(step: 1, onSkip: guide.closeGuide) {
            title("Fill your feed")
            WebOfTrustDiagram()
                .frame(height: 132)
                .frame(maxWidth: .infinity)
            bodyText("Nostr starts empty. No algorithm picks for you. Follow a few people, and the people they follow become your web of trust. It fills your feed and filters out spam.")
            HStack(spacing: 8) {
                Spacer()
                Button("Not now", action: guide.closeGuide)
                    .font(.appBody)
                    .foregroundColor(.secondary)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 8)
                PrimaryButton(title: "Let's fill it", action: guide.beginFilling)
            }
        }
    }
}

/// You, your follows, their follows.
private struct WebOfTrustDiagram: View {
    private static let colors: [Color] = [
        Color(red: 0.76, green: 0.25, blue: 0.05), Color(red: 0.05, green: 0.45, blue: 0.56),
        Color(red: 0.49, green: 0.23, blue: 0.93), Color(red: 0.08, green: 0.50, blue: 0.24),
        Color(red: 0.73, green: 0.11, blue: 0.11),
    ]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2 - 6)
            let mids: [CGPoint] = (0..<5).map { k in
                let a = -Double.pi / 2 + Double(k) * 2 * .pi / 5
                return CGPoint(x: center.x + 52 * cos(a), y: center.y + 44 * sin(a))
            }
            for p in mids {
                let base = atan2(p.y - center.y, p.x - center.x)
                for j in -1...1 {
                    let a = base + Double(j) * 0.38
                    let o = CGPoint(x: center.x + 120 * cos(a), y: center.y + 52 * sin(a))
                    var line = Path(); line.move(to: p); line.addLine(to: o)
                    context.stroke(line, with: .color(.white.opacity(0.18)), lineWidth: 1)
                    context.fill(Path(ellipseIn: CGRect(x: o.x - 5, y: o.y - 5, width: 10, height: 10)),
                                 with: .color(Color(white: 0.36)))
                }
            }
            for p in mids {
                var line = Path(); line.move(to: center); line.addLine(to: p)
                context.stroke(line, with: .color(Color.havenPurple.opacity(0.7)), lineWidth: 1.5)
            }
            for (k, p) in mids.enumerated() {
                let r = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
                context.fill(Path(ellipseIn: r), with: .color(Self.colors[k]))
                context.stroke(Path(ellipseIn: r), with: .color(Color(white: 0.12)), lineWidth: 2)
            }
            let you = CGRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34)
            context.fill(Path(ellipseIn: you), with: .color(.havenPurple))
            context.stroke(Path(ellipseIn: you), with: .color(Color(white: 0.12)), lineWidth: 3)
            context.draw(Text("You").font(.system(size: 11, weight: .bold)).foregroundColor(.white), at: center)
            context.draw(Text("your follows").font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2 - 100, y: size.height - 6))
            context.draw(Text("their follows").font(.system(size: 10)).foregroundColor(.secondary),
                         at: CGPoint(x: size.width / 2 + 100, y: size.height - 6))
        }
        .accessibilityElement()
        .accessibilityLabel("You, connected to the people you follow, connected to the people they follow.")
    }
}

// MARK: - 2. Topics

private struct TopicsCard: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared
    @ObservedObject private var interests = InterestListService.shared
    @State private var selected: [String] = []
    @State private var showingMore = false
    @State private var seeded = false

    var body: some View {
        GuideCard(step: 2, onSkip: guide.closeGuide) {
            title("What are you into?")
            bodyText("Pick a few topics. You'll see posts about them from everyone, so you can find people to follow.")
            ScrollView {
                TopicChips(topics: VaultTopics.starter + selected.filter { !VaultTopics.starter.contains($0) },
                           selected: $selected, onMore: { showingMore = true })
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: FillYourFeedGuide.showPostsTitle(selected: selected.count), wide: true,
                          disabled: selected.isEmpty) {
                guide.showPosts(topics: selected)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            // Topics this account already follows start picked.
            selected = interests.hashtags
        }
        .sheet(isPresented: $showingMore) {
            MoreTopicsSheet(selected: $selected)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct TopicChips: View {
    let topics: [String]
    @Binding var selected: [String]
    var onMore: (() -> Void)? = nil

    var body: some View {
        ChipFlow(spacing: 8) {
            ForEach(topics, id: \.self) { topic in
                let on = selected.contains(topic)
                Button {
                    if on { selected.removeAll { $0 == topic } } else { selected.append(topic) }
                } label: {
                    Text("#\(topic)")
                        .font(.appSubheadline.weight(on ? .semibold : .regular))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(on ? Color.havenPurple : Color(white: 0.18)))
                        .overlay(Capsule().stroke(on ? Color.havenPurple : Color.white.opacity(0.1), lineWidth: 1))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("#\(topic)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            if let onMore {
                Button(action: onMore) {
                    Text("More topics…")
                        .font(.appSubheadline)
                        .foregroundColor(.havenPurple)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundColor(.havenPurple))
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MoreTopicsSheet: View {
    @Binding var selected: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("More topics").font(.appTitle3.weight(.bold))
                Text("Or type any hashtag.").font(.appSubheadline).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("#anything", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit(add)
                        .accessibilityLabel("Type a hashtag")
                    PrimaryButton(title: "Add", disabled: VaultTopics.normalize(typed) == nil, action: add)
                }
                TopicChips(topics: VaultTopics.more + selected.filter {
                    !VaultTopics.starter.contains($0) && !VaultTopics.more.contains($0)
                }, selected: $selected)
                PrimaryButton(title: "Done", wide: true) { dismiss() }
                    .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func add() {
        guard let tag = VaultTopics.normalize(typed) else { return }
        if !selected.contains(tag) { selected.append(tag) }
        typed = ""
    }
}

/// Chips that wrap onto as many rows as they need.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width && x > 0 {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 3. Hint

private struct HintCard: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared

    var body: some View {
        GuideCard(step: 3, onSkip: guide.closeGuide) {
            title("Find people you like")
            bodyText("Tap anyone to see their profile and posts first. When you like what you see, follow them. Each follow fills a spot down by the tabs. Five gets your feed going.")
            HStack {
                Spacer()
                PrimaryButton(title: "Got it", action: guide.dismissHint)
            }
        }
    }
}

// MARK: - 4. Your feed is ready

private struct ReadyCard: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared
    @ObservedObject private var nostr = NostrService.shared
    @State private var keepTopics = true
    @State private var reach: Int?

    var body: some View {
        GuideCard {
            Text("Your feed is ready")
                .font(.appTitle3.weight(.bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: -10) {
                ForEach(guide.meter.recent.suffix(VaultMeter.goal), id: \.self) { pubkey in
                    AvatarView(url: nostr.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 48)
                        .overlay(Circle().stroke(Color(white: 0.12), lineWidth: 3))
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            VStack(spacing: 2) {
                if let reach, reach > 0 {
                    Text(reach.formatted())
                        .font(.appTitle.weight(.bold))
                        .foregroundColor(.white)
                    Text("people your \(guide.meter.count) follows bring into your web of trust")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Counting the people your follows bring in…")
                        .font(.appFootnote)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            VStack(spacing: 8) {
                option(title: "Keep my topics", detail: "Topic posts from people in your web of trust.", on: keepTopics) {
                    keepTopics = true
                }
                option(title: "Only my web of trust", detail: "Drop the topics and just see Following.", on: !keepTopics) {
                    keepTopics = false
                }
            }
            PrimaryButton(title: "Go to Following", wide: true) {
                guide.goToFollowing(keepTopics: keepTopics)
            }
        }
        .onAppear {
            FeedService.shared.countExtendedNetwork { count in reach = count }
        }
    }

    private func option(title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.appBody)
                    .foregroundColor(on ? .havenPurple : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appSubheadline.weight(.semibold)).foregroundColor(.white)
                    Text(detail).font(.appFootnote).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? Color.havenPurple.opacity(0.18) : Color(white: 0.18)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Color.havenPurple : Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - the web of trust (10 follows)

private struct MasterCard: View {
    @ObservedObject private var guide = FillYourVaultCoordinator.shared

    var body: some View {
        GuideCard(border: Gold.mid) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Gold.light, Gold.mid, Gold.dark], center: UnitPoint(x: 0.35, y: 0.3),
                                         startRadius: 2, endRadius: 60))
                    .shadow(color: Gold.mid.opacity(0.45), radius: 15)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 44, weight: .black))
                    .foregroundColor(Color(red: 0.23, green: 0.16, blue: 0))
            }
            .frame(width: 96, height: 96)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            Text(FillYourFeedGuide.masterCardTitle)
                .font(.appTitle3.weight(.bold))
                .foregroundColor(Gold.light)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            Text(FillYourFeedGuide.masterCardBody)
                .font(.appSubheadline)
                .foregroundColor(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            PrimaryButton(title: "Done", wide: true,
                          fill: AnyShapeStyle(LinearGradient(colors: [Gold.light, Gold.mid], startPoint: .topLeading, endPoint: .bottomTrailing)),
                          textColor: Color(red: 0.23, green: 0.16, blue: 0),
                          action: guide.dismissMasterCard)
        }
    }
}

// MARK: - Picks sheet (tap the meter)

private struct FeedPicksSheet: View {
    let onHide: () -> Void
    @ObservedObject private var guide = FillYourVaultCoordinator.shared
    @ObservedObject private var nostr = NostrService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your feed").font(.appTitle3.weight(.bold))
                Text("Your web of trust is the people you follow, plus the people they follow. Nobody else picks it.")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
                Text("Following (\(guide.meter.count))")
                    .font(.appCaption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                if guide.meter.recent.isEmpty {
                    Text("Nobody yet. Tap someone in the feed to see their profile.")
                        .font(.appSubheadline)
                        .foregroundColor(.secondary)
                }
                ForEach(guide.meter.recent.reversed(), id: \.self) { pubkey in
                    let profile = nostr.profiles[pubkey]
                    HStack(spacing: 12) {
                        AvatarView(url: profile?.pictureURL, pubkey: pubkey, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile?.bestName ?? String(pubkey.prefix(10)))
                                .font(.appSubheadline.weight(.semibold))
                                .lineLimit(1)
                            if let nip05 = profile?.nip05, !nip05.isEmpty {
                                Text(nip05).font(.appFootnote).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Button("Unfollow") { _ = FeedService.shared.unfollowUser(pubkey) }
                            .font(.appSubheadline.weight(.semibold))
                            .foregroundColor(.havenPurple)
                            .frame(minHeight: 44)
                    }
                    Divider()
                }
                PrimaryButton(title: "Done", wide: true) { dismiss() }
                    .padding(.top, 6)
                Button("Hide the meter", action: onHide)
                    .font(.appBody)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(20)
        }
    }
}
