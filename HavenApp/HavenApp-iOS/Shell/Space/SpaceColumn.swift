import SwiftUI

/// The iPad's right-hand column in landscape, after the web's desktop "Your
/// space": the user's widgets (all six the layout has) in the order they chose, each collapsible to its header, all on one screen. Edit moves, removes and
/// adds them; the layout is the account's (`SpaceLayoutStore`), synced with
/// the web. A thin icon rail on its right edge is always showing, folded or
/// not (Logen, 2026-11-04): the dashboard (every widget together) on top,
/// then one icon per widget, which opens just that widget, full height. A
/// tap on the open one folds the column; any tap while folded opens it. The
/// fold stays on this device, per account.
struct SpaceColumn: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var store = SpaceLayoutStore.shared
    @ObservedObject private var dmService = DMService.shared
    @ObservedObject private var feedService = FeedService.shared
    @StateObject private var liveVault = LiveVaultModel()
    @StateObject private var liveNow = LiveNowModel()
    @State private var folded = false
    @State private var editing = false
    /// The widget the rail opened on its own, or nil for the dashboard.
    @State private var selected: String?

    private var owner: String { configService.activeAccountHexPubkey.lowercased() }
    /// Every widget the account's layout has, as on the web (Logen,
    /// 2026-11-05: all six on the rail and in Edit, undoing #1690's three).
    static let ids = SpaceLayoutStore.panelIds
    private var ids: [String] { Self.ids }

    var body: some View {
        HStack(spacing: 0) {
            if !folded {
                VStack(spacing: 0) {
                    spaceBar
                    if let id = selected { single(id) } else { panels }
                }
                .frame(width: LiveVaultLayout.openWidth)
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1)
                    .ignoresSafeArea()
            }
            rail
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // space.css: a warm wash at the top over near-black.
            ZStack(alignment: .top) {
                Color(red: 5 / 255, green: 4 / 255, blue: 3 / 255)
                LinearGradient(colors: [Color.havenPurple.opacity(0.08), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .onChange(of: owner, initial: true) { _, hex in
            folded = UserDefaults.standard.bool(forKey: LiveVault.foldedKey(hex))
            editing = false
            selected = nil
            liveVault.attach(hex)
        }
        // Live now runs while its panel is open or the column is folded (the
        // strip shows its count); the column owns it, so the fold's swap of
        // panel for strip can't stop it.
        .onChange(of: "\(owner)|\(liveNowWanted)", initial: true) { _, _ in
            liveNow.attach(owner)
            if liveNowWanted { liveNow.start() } else { liveNow.stop() }
        }
        // The follow list can arrive after Live now first looked: look again.
        .onChange(of: feedService.followedPubkeys.isEmpty) { _, empty in
            if !empty && liveNowWanted { liveNow.refresh() }
        }
        .onChange(of: relayReady, initial: true) { _, ready in
            if ready { liveVault.startFetchIfIdle() }
        }
        // LiveNowPanel stops the shared model when it leaves the screen; the
        // rail's count still needs it, so start it again after each switch.
        .onChange(of: "\(folded)|\(selected ?? "")|\(editing)") { _, _ in
            DispatchQueue.main.async { if liveNowWanted { liveNow.start() } }
        }
        // A widget taken off the layout (here or on the web) closes if it was open alone.
        .onChange(of: railIds) { _, now in
            if let id = selected, !now.contains(id) { selected = nil }
        }
    }

    /// The rail always shows Live now's count, so it asks whenever that widget is on.
    private var liveNowWanted: Bool {
        railIds.contains(LiveNow.panelId)
    }

    /// One rail icon per widget the layout shows, in its order.
    private var railIds: [String] { store.layout.shownPanels(ids).map(\.id) }

    private var relayReady: Bool { relayManager.isRunning && !relayManager.isBooting }

    // MARK: Bar

    /// The column's own bar, as on the web: its name, Edit, and the fold button.
    private var spaceBar: some View {
        HStack(spacing: 4) {
            Text(selected.map { Self.info($0).title } ?? "Your space")
                .font(.appSystem(size: 17, weight: .bold))
            Spacer()
            if selected != nil {
                barButton("sidebar.right", label: "Fold Your space") { setFolded(true) }
            } else if editing {
                Button("Done") { withAnimation(.easeInOut(duration: 0.2)) { editing = false } }
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(.havenPurple)
                    .padding(.horizontal, 8)
            } else {
                barButton("pencil", label: "Edit Your space") {
                    withAnimation(.easeInOut(duration: 0.2)) { editing = true }
                }
                barButton("sidebar.right", label: "Fold Your space") { setFolded(true) }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 10)
        // The feed's floating pills' row: same height from the same top, so
        // the title sits level with them. No rule under it; the feed's half
        // has none.
        .frame(height: PadTopBar.height)
    }

    private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.appSystem(size: 16, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .accessibilityLabel(label)
    }

    // MARK: Panels

    @ViewBuilder
    private var panels: some View {
        let shown = store.layout.shownPanels(ids)
        let hidden = store.layout.hiddenPanels(ids)
        // Open panels share the column equally and scroll inside, so every
        // panel's header stays on one screen; with none open they sit at the top.
        let anyOpenFills = !editing && shown.contains { $0.open }
        VStack(spacing: 12) {
            if shown.isEmpty && !editing {
                VStack(spacing: 10) {
                    Text("Nothing here.")
                        .font(.appSystem(size: 15, weight: .semibold))
                    Button("Edit to add panels") { withAnimation { editing = true } }
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.havenPurple)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, panel in
                card(panel, index: index, count: shown.count)
            }
            if editing { editFooter(hidden: hidden) }
            if !anyOpenFills { Spacer(minLength: 0) }
        }
        .padding(12)
    }

    @ViewBuilder
    private func card(_ panel: SpaceLayout.Panel, index: Int, count: Int) -> some View {
        let info = Self.info(panel.id)
        let fills = panel.open && !editing
        SpacePanelCard(
            title: info.title,
            symbol: info.symbol,
            count: panel.id == "live-vault" ? liveVault.unreadCount
                : panel.id == "messages" ? dmService.totalUnreadCount
                : panel.id == LiveNow.panelId ? liveNow.streams.count : 0,
            open: panel.open,
            editing: editing,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            onToggleOpen: { withAnimation(.easeInOut(duration: 0.2)) { store.setPanel(panel.id, open: !panel.open) } },
            onMove: { delta in withAnimation(.easeInOut(duration: 0.2)) { store.movePanel(panel.id, by: delta, ids: ids) } },
            onHide: { withAnimation(.easeInOut(duration: 0.2)) { store.setPanel(panel.id, on: false) } }
        ) {
            ScrollView { panelContent(panel.id) }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: !fills)
    }

    @ViewBuilder
    private func panelContent(_ id: String) -> some View {
        switch id {
        case "live-vault": LiveVaultPanel(model: liveVault)
        case "wot-mini": WotMiniPanel()
        case LiveNow.panelId: LiveNowPanel(model: liveNow)
        case "messages": MessagesPeekPanel()
        case "my-devices": MyDevicesPanel()
        case "on-this-day": OnThisDayPanel()
        default: EmptyView()
        }
    }

    private func editFooter(hidden: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hidden, id: \.self) { id in
                let info = Self.info(id)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.setPanel(id, on: true) }
                } label: {
                    Label("Add \(info.title)", systemImage: "plus")
                        .font(.appSystem(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(.havenPurple)
            }
            feedPins
            Button("Reset to default") { withAnimation(.easeInOut(duration: 0.2)) { store.resetPanels() } }
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }

    /// Feed types the left rail can carry (Logen, 2026-11-05): tap to pin
    /// one there (`{"type":"feed","id":"music"}`), tap again to take it off.
    /// Following is the Feed section itself, so it isn't offered.
    private var feedPins: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feeds on your rail")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.top, 10)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(FeedMode.allCases.filter { $0 != .following }, id: \.self) { mode in
                    let kind = SpaceLayout.Pin.Kind.feed(mode.pinId)
                    let pinned = store.isPinned(kind)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if pinned, let pin = SpaceLayout.Pin.favourite(kind) {
                                store.removePin(pin.id)
                            } else if let pin = SpaceLayout.Pin.favourite(kind) {
                                store.addPin(pin)
                            }
                        }
                    } label: {
                        Label(mode.displayName, systemImage: pinned ? "checkmark" : mode.symbolName)
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(pinned ? .white : .havenPurple)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Capsule().fill(pinned ? Color.havenPurple : Color.havenPurple.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinned ? "\(mode.displayName) on your rail. Take off" : "Add \(mode.displayName) to your rail")
                }
            }
        }
    }

    static func info(_ id: String) -> (title: String, symbol: String) {
        switch id {
        case "live-vault": return ("Live Vault", VaultMode.activity.symbol)
        case "wot-mini": return ("Web of Trust", TrustMap.Layer.everyone.symbolName)
        case "messages": return ("Messages", "bubble.left.and.bubble.right")
        case "my-devices": return ("My devices", "laptopcomputer.and.iphone")
        case LiveNow.panelId: return ("Live now", "dot.radiowaves.left.and.right")
        case "on-this-day": return ("On this day", "clock.arrow.circlepath")
        default: return (id, "square")
        }
    }

    // MARK: Rail

    /// The icon rail: always on the column's right edge.
    private var rail: some View {
        VStack(spacing: 6) {
            railButton(nil, symbol: "square.grid.2x2", title: "Your space")
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 24, height: 1)
                .padding(.vertical, 4)
            ForEach(railIds, id: \.self) { id in
                let info = Self.info(id)
                railButton(id, symbol: info.symbol, title: info.title,
                           badge: id == LiveNow.panelId ? liveNow.streams.count : 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, (PadTopBar.height - 40) / 2)
        .frame(width: LiveVaultLayout.foldedWidth)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func railButton(_ id: String?, symbol: String, title: String, badge: Int = 0) -> some View {
        let isOpen = !folded && selected == id
        return Button { tapRail(id) } label: {
            Image(systemName: symbol)
                .font(.appSystem(size: 17, weight: .semibold))
                .foregroundColor(isOpen ? .havenPurple : .secondary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isOpen ? Color.havenPurple.opacity(0.16) : Color.clear))
                .overlay(alignment: .topTrailing) {
                    if let text = AccountUnread.badge(badge) {
                        Text(text)
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Color.havenPurple))
                            .offset(x: 4, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOpen ? "Fold \(title)" : (badge > 0 ? "\(title), \(badge)" : title))
        .help(title)
    }

    /// Folded: open on that icon. Open on it already: fold. Otherwise switch to it.
    private func tapRail(_ id: String?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if folded {
                selected = id
                setFolded(false)
            } else if selected == id {
                setFolded(true)
            } else {
                selected = id
                editing = false
            }
        }
    }

    /// One widget on its own, filling the column.
    private func single(_ id: String) -> some View {
        ScrollView { panelContent(id) }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(12)
    }

    private func setFolded(_ value: Bool) {
        folded = value
        if value { editing = false }
        UserDefaults.standard.set(value, forKey: LiveVault.foldedKey(owner))
    }
}
