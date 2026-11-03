import SwiftUI

/// The iPad's right-hand column in landscape, after the web's desktop "Your
/// space": the user's panels (Live Vault, WoT mini, Messages peek) in the
/// order they chose, each collapsible to its header. Edit moves, removes and
/// adds them; the layout is the account's (`SpaceLayoutStore`), synced with
/// the web. The whole column folds to a thin strip with Live Vault's unread
/// count; that choice stays on this device, per account.
struct SpaceColumn: View {
    @EnvironmentObject var configService: ConfigService
    @EnvironmentObject var relayManager: RelayProcessManager
    @ObservedObject private var store = SpaceLayoutStore.shared
    @ObservedObject private var dmService = DMService.shared
    @StateObject private var liveVault = LiveVaultModel()
    @State private var folded = false
    @State private var editing = false

    private var owner: String { configService.activeAccountHexPubkey.lowercased() }
    private var ids: [String] { SpaceLayoutStore.panelIds }

    var body: some View {
        Group {
            if folded {
                foldedStrip(count: liveVault.unreadCount)
            } else {
                VStack(spacing: 0) {
                    spaceBar
                    panels
                }
                .frame(width: LiveVaultLayout.openWidth)
            }
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
            liveVault.attach(hex)
        }
        .onChange(of: relayReady, initial: true) { _, ready in
            if ready { liveVault.startFetchIfIdle() }
        }
    }

    private var relayReady: Bool { relayManager.isRunning && !relayManager.isBooting }

    // MARK: Bar

    /// The column's own bar, as on the web: its name, Edit, and the fold button.
    private var spaceBar: some View {
        HStack(spacing: 4) {
            Text("Your space")
                .font(.appSystem(size: 17, weight: .bold))
            Spacer()
            if editing {
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
        // Live Vault takes the slack when it is open; otherwise the panels
        // sit at the top.
        let liveVaultFills = !editing && shown.contains { $0.id == "live-vault" && $0.open }
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
            if !liveVaultFills { Spacer(minLength: 0) }
        }
        .padding(12)
    }

    @ViewBuilder
    private func card(_ panel: SpaceLayout.Panel, index: Int, count: Int) -> some View {
        let info = Self.info(panel.id)
        SpacePanelCard(
            title: info.title,
            symbol: info.symbol,
            count: panel.id == "live-vault" ? liveVault.unreadCount
                : panel.id == "messages" ? dmService.totalUnreadCount : 0,
            open: panel.open,
            editing: editing,
            canMoveUp: index > 0,
            canMoveDown: index < count - 1,
            onToggleOpen: { withAnimation(.easeInOut(duration: 0.2)) { store.setPanel(panel.id, open: !panel.open) } },
            onMove: { delta in withAnimation(.easeInOut(duration: 0.2)) { store.movePanel(panel.id, by: delta) } },
            onHide: { withAnimation(.easeInOut(duration: 0.2)) { store.setPanel(panel.id, on: false) } }
        ) {
            switch panel.id {
            case "live-vault": LiveVaultPanel(model: liveVault)
            case "wot-mini": WotMiniPanel()
            case "messages":
                ScrollView { MessagesPeekPanel() }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 320)
            default: EmptyView()
            }
        }
        .frame(maxHeight: panel.id == "live-vault" && panel.open && !editing ? .infinity : nil)
        .fixedSize(horizontal: false, vertical: panel.id != "live-vault" || !panel.open || editing)
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
            Button("Reset to default") { withAnimation(.easeInOut(duration: 0.2)) { store.resetPanels() } }
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
    }

    static func info(_ id: String) -> (title: String, symbol: String) {
        switch id {
        case "live-vault": return ("Live Vault", VaultMode.activity.symbol)
        case "wot-mini": return ("Web of Trust", TrustMap.Layer.everyone.symbolName)
        case "messages": return ("Messages", "bubble.left.and.bubble.right")
        default: return (id, "square")
        }
    }

    // MARK: Fold

    private func foldedStrip(count: Int) -> some View {
        Button { setFolded(false) } label: {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left")
                    .font(.appSystem(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
                Image(systemName: VaultMode.activity.symbol)
                    .font(.appSystem(size: 18))
                    .foregroundColor(.havenPurple)
                if let badge = AccountUnread.badge(count) {
                    Text(badge)
                        .font(.appSystem(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.havenPurple))
                }
                Spacer()
            }
            .padding(.top, 16)
            .frame(width: LiveVaultLayout.foldedWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "Open Your space, \(count) new" : "Open Your space")
    }

    private func setFolded(_ value: Bool) {
        folded = value
        if value { editing = false }
        UserDefaults.standard.set(value, forKey: LiveVault.foldedKey(owner))
    }
}
