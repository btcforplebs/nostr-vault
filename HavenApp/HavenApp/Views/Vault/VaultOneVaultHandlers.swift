import SwiftUI

#if os(macOS)

/// The Vault tab's own wiring, which the iPhone's body has (VaultView.swift)
/// and the Mac's body did not, because the Mac never showed the Vault tab:
/// the page pill's tick and its "New" dots, the hold-menu page, Articles and
/// Highlights' first page, the Vault list's filter and visit marks. The Mac
/// one Vault (MacVaultFold) needs the same, so the pill and the lists behave
/// as they do on the phone. Each handler is a no-op outside the one Vault.
struct VaultOneVaultHandlers: ViewModifier {
    let view: VaultView

    func body(content: Content) -> some View {
        let v = view
        return content
            .onChange(of: v.vaultModesWithNews, initial: true) { _, modes in
                if v.vaultTabHostsMedia { VaultSection.shared.newModes = modes }
            }
            .onReceive(VaultSection.shared.$showsMedia) { v.vaultShowsMedia = $0 }
            .task(id: v.firstPageKey) {
                if v.vaultTabHostsMedia { v.loadFirstPageInScope() }
            }
            .onChange(of: v.vaultSection.opensNewActivity, initial: true) { _, opens in
                if opens && v.vaultTabHostsMedia { v.openNewActivity() }
            }
            .onChange(of: v.vaultMode, initial: true) { _, mode in
                if v.vaultTabHostsMedia { v.vaultSection.listMode = mode }
            }
            .onChange(of: v.vaultSection.pendingMode, initial: true) { _, mode in
                guard v.vaultTabHostsMedia, let mode else { return }
                v.vaultSection.pendingMode = nil
                mode.select()
            }
            .onChange(of: v.activityFilter) { _, _ in
                v.maxDisplayedItems = 50
                v.scheduleUpdateDisplayData()
            }
            .onChange(of: v.modeInSight, initial: true) { old, mode in
                guard v.vaultTabHostsMedia else { return }
                if let mode { v.relayManager.markRelayViewed(mode) }
                if mode == .activity || mode == .messages {
                    v.relayManager.markDMsSeen(unread: DMService.shared.totalUnreadCount)
                }
                if mode == .activity { v.activityVisit(arriving: true) } else if old == .activity { v.activityVisit(arriving: false) }
            }
            .onChange(of: v.relayManager.newActivityModes) { _, _ in
                if v.vaultTabHostsMedia, let mode = v.modeInSight { v.relayManager.markRelayViewed(mode) }
            }
    }
}

#endif
