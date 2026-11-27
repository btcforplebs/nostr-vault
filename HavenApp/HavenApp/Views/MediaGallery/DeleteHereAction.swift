import SwiftUI

/// "Delete from this device" (A3) from the Media list and grid: asks once,
/// then removes this device's copy only if another place proves it holds the
/// file (`BlossomService.deleteHere`), and says what happened.
@MainActor
enum DeleteHereAction {
    /// - Returns: whether this device's copy is gone.
    static func run(hash: String, configService: ConfigService, nostrService: NostrService) async -> Bool {
        let service = BlossomService(configService: configService, nostrService: nostrService)
        let result = await service.deleteHere(sha256: hash)
        switch result {
        case .deleted(let holders):
            MediaCacheService.shared.blossomFolderIndex.invalidate()
            await BlossomBackupStore.shared.refresh(hash: hash, service: service, force: true)
            let hosts = holders.compactMap { URL(string: $0)?.host }
            let where_ = hosts.count == 1 ? hosts[0] : "\(hosts.count) places"
            ActionToastManager.shared.show(icon: "minus.circle", message: "Removed from this device. Still on \(where_).", tone: .success)
            return true
        case .refused(let why), .failed(let why):
            ActionToastManager.shared.show(icon: "exclamationmark.triangle.fill", message: why, tone: .error, seconds: 6)
            return false
        }
    }
}

private struct DeleteHereConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete from this device?", isPresented: $isPresented, titleVisibility: .visible) {
            Button("Delete from this device", role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays on your media servers and your other devices. First we check that one of them has the whole file; if none does, nothing is deleted. It won't download here again unless you Save to Vault.")
        }
    }
}

extension View {
    func confirmDeleteHere(_ isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        modifier(DeleteHereConfirmation(isPresented: isPresented, action: action))
    }
}

extension MediaGalleryView {
    /// The tile stays when a note or file note still links the file (it then
    /// shows from the servers); a file only this device's scan knew leaves.
    func deleteMediaHere(item: MediaItem) {
        guard let sha256 = deleteHash(for: item) else { return }
        Task {
            guard await DeleteHereAction.run(hash: sha256, configService: configService, nostrService: nostrService) else { return }
            self.blossomCache.items.removeAll(where: { normalizedKeyStatic(for: $0.url) == sha256 })
            loadLocalMedia(force: true)
            scheduleUpdateDisplayData()
        }
    }
}
