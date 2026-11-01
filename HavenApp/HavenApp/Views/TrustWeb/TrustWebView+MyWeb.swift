import SwiftUI

#if os(iOS)
extension TrustWebView {
    // MARK: - My Web

    /// The WOT tab's floating button, where the other tabs have Post. It
    /// opens My Web, the tab's dashboard, as the Vault tab's button opens
    /// the Vault Dashboard. It steps aside while a trust card or a profile
    /// is up (Logen, 10/14).
    var myWebHUD: some View {
        let shown = card == nil && !wotSheetOpen && !searchFocused
        return ZStack(alignment: .bottomTrailing) {
            if shown {
                ChromeFold(anchor: .bottomTrailing) { myWebButton }
                    .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        // Shares the row above the tab bar with the music mini player.
        .modifier(FloatingButtonSlot())
        .animation(Motion.panel, value: shown)
        .onReceive(NotificationCenter.default.publisher(for: .composeFromTabBar)) { note in
            // The folded tab bar's button, on this tab.
            guard (note.object as? Int) == 3 else { return }
            closeCard()
            openMyWeb()
        }
        .sheet(isPresented: $myWebOpen) {
            NavigationStack {
                myWebDashboard
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { myWebOpen = false }
                        }
                        ToolbarItem(placement: .principal) {
                            Label("My Web", systemImage: TrustMap.Layer.everyone.symbolName)
                                .labelStyle(.titleAndIcon)
                                .font(.appSystem(size: 17, weight: .bold, design: .rounded))
                        }
                    }
            }
        }
    }

    func openMyWeb() {
        if followsBackLoaded == nil { loadFollowsBack() }
        myWebOpen = true
    }

    private var myWebButton: some View {
        Button { openMyWeb() } label: {
            HStack(spacing: 6) {
                Image("WoTTab")
                    .resizable()
                    .frame(width: 18, height: 18)
                Text("My Web")
                    .font(.appSystem(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundColor(.white)
            .frame(height: FloatingButtonRow.buttonHeight)
            .padding(.horizontal, 18)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [Color.havenPurple, Color.havenPurpleLight],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: Color.havenPurple.opacity(0.35), radius: 8, x: 0, y: 4)
            )
        }
        .buttonStyle(PressScaleButtonStyle())
        .hoverEffect(.lift)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("My Web"))
        .accessibilityHint(Text("Opens your web's dashboard"))
    }

    private var myWebDashboard: MyWebDashboardView {
        let matches = filterMatches
        return MyWebDashboardView(
            counts: layerCounts,
            layers: TrustMap.layers(hasVouches: vouches != nil),
            hasVouches: vouches != nil,
            follows: myFollows.subtracting([me]).count,
            talk: matches[.talk]?.count ?? 0,
            followsBack: followsBackLoaded == true ? matches[.followsBack]?.count ?? 0 : nil,
            followsBackChecking: followsBackLoaded == nil,
            rebuiltAt: FeedService.shared.wotCacheStamp?.modified,
            rebuilding: refreshStep != nil,
            layer: layer,
            filters: filters,
            onLayer: { picked in
                jump(to: 0)
                layer = picked
                myWebOpen = false
            },
            onFilter: { filter in
                if !filters.contains(filter) { toggle(filter) }
                myWebOpen = false
            },
            onRebuild: { refresh() }
        )
    }
}

/// My Web: what the WOT tab's globe holds, in numbers. A row puts that part
/// of your web on the globe and closes the page.
struct MyWebDashboardView: View {
    let counts: [TrustMap.Layer: Int]
    let layers: [TrustMap.Layer]
    let hasVouches: Bool
    let follows: Int
    let talk: Int
    /// nil while it is unknown: still being read, or the relay has none.
    let followsBack: Int?
    let followsBackChecking: Bool
    let rebuiltAt: Date?
    let rebuilding: Bool
    let layer: TrustMap.Layer
    let filters: Set<TrustMap.Filter>
    let onLayer: (TrustMap.Layer) -> Void
    let onFilter: (TrustMap.Filter) -> Void
    let onRebuild: () -> Void

    /// Live arrivals: the bar's antenna, and which feeds' notes fly.
    @AppStorage(LiveArcsSetting.key) private var liveArcsOn = LiveArcsSetting.defaultOn
    @AppStorage(LiveArcsSetting.key(.following)) private var followingOn = true
    @AppStorage(LiveArcsSetting.key(.discover)) private var discoverOn = true
    @AppStorage(LiveArcsSetting.key(.global)) private var globalOn = true

    @Environment(\.openURL) private var openURL
    static let plebsVsZombiesURL = URL(string: "https://plebsvszombies.cc")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headline
                DashboardSection(title: "Who you can see") {
                    ForEach(Array(layers.enumerated()), id: \.element) { index, item in
                        if index > 0 { DashboardDivider() }
                        countRow(icon: item.symbolName, title: item.title, detail: detail(for: item),
                                 count: counts[item] ?? 0, selected: item == layer) { onLayer(item) }
                    }
                }
                DashboardSection(title: "With you") {
                    countRow(icon: TrustMap.Filter.talk.symbolName, title: TrustMap.Filter.talk.title,
                             detail: "Replies, reposts, likes and zaps, either way",
                             count: talk, selected: filters.contains(.talk)) { onFilter(.talk) }
                    DashboardDivider()
                    countRow(icon: TrustMap.Filter.followsBack.symbolName, title: TrustMap.Filter.followsBack.title,
                             detail: followsBackDetail,
                             count: followsBack, selected: filters.contains(.followsBack)) { onFilter(.followsBack) }
                }
                DashboardSection(title: "Live arrivals") {
                    switchRow(icon: "antenna.radiowaves.left.and.right", title: "Stars on the globe",
                              detail: "A star for each new note as it arrives", isOn: $liveArcsOn)
                    DashboardDivider()
                    switchRow(icon: "person.2.fill", title: GlobeArcs.Ring.following.title,
                              detail: "Your follows' notes, from the inner ring. The fewest", isOn: $followingOn)
                        .disabled(!liveArcsOn)
                    DashboardDivider()
                    switchRow(icon: "sparkles", title: GlobeArcs.Ring.discover.title,
                              detail: "Your wider web, from the next ring out. More", isOn: $discoverOn)
                        .disabled(!liveArcsOn)
                    DashboardDivider()
                    switchRow(icon: "globe", title: GlobeArcs.Ring.global.title,
                              detail: "The rest of Global, from the outer haze. The most", isOn: $globalOn)
                        .disabled(!liveArcsOn)
                }
                LiveArcsShowSection(liveArcsOn: liveArcsOn)
                DashboardSection(title: "Upkeep") {
                    DashboardRow(icon: "arrow.clockwise", title: "Rebuild your web",
                                 detail: rebuiltText, state: .info) {
                        RowButton(title: "Rebuild", isLoading: rebuilding, action: onRebuild)
                            .disabled(rebuilding)
                    }
                    DashboardDivider()
                    // Cleaning up follows happens on Plebs vs. Zombies, not in this app (Logen 2026-11-01).
                    DashboardRow(icon: "arrow.up.right.square", title: "Plebs vs Zombies",
                                 detail: "Clean up your follows on plebsvszombies.cc", state: .info) {
                        RowButton(title: "Open") { openURL(Self.plebsVsZombiesURL) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }

    /// The one big number: everyone on your globe.
    private var headline: some View {
        let everyone = counts[.everyone] ?? 0
        return HStack(spacing: 14) {
            Image("WoTTab")
                .resizable()
                .frame(width: 34, height: 34)
                .padding(10)
                .background(Color.havenPurple.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(everyone.formatted()) people")
                    .font(.appSystem(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("in your web: who you follow, and who they follow")
                    .font(.appSystem(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.platformCardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.platformCardBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func detail(for item: TrustMap.Layer) -> String {
        switch item {
        case .everyone: return "Your whole web"
        case .following: return "People you follow"
        case .close: return "Followed by \(TrustMap.closeVouches)+ people you follow"
        case .furtherOut:
            return hasVouches ? "Followed by fewer than \(TrustMap.closeVouches) people you follow"
                              : "Followed by people you follow"
        }
    }

    private var followsBackDetail: String {
        if let followsBack, follows > 0 {
            return "\(followsBack.formatted()) of the \(follows.formatted()) people you follow"
        }
        return followsBackChecking ? "Checking who follows you…" : "Your vault hasn't seen your followers yet"
    }

    private var rebuiltText: String {
        if rebuilding { return "Rebuilding now…" }
        guard let rebuiltAt else { return "Your vault rebuilds it once a day" }
        return "Last rebuilt \(rebuiltAt.formatted(.relative(presentation: .named))). Your vault rebuilds it once a day"
    }

    private func switchRow(icon: String, title: String, detail: String, isOn: Binding<Bool>) -> some View {
        DashboardRow(icon: icon, title: title, detail: detail, state: .info) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(.havenPurple)
        }
    }

    private func countRow(icon: String, title: String, detail: String, count: Int?, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                RowIcon(icon: icon, state: .info)
                RowText(title: title, detail: detail)
                Text(count.map { $0.formatted() } ?? "–")
                    .font(.appSystem(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(selected ? .havenPurple : .primary)
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(selected ? .havenPurple : .secondary)
                    .frame(width: 14)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(count.map { "\($0.formatted()) people" } ?? "Not known yet"))
        .accessibilityHint(Text("Shows them on the globe"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
