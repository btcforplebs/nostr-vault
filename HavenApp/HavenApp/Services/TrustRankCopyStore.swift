import Foundation
import Combine

/// The phone's copy of its Haven's trust rank, one per account
/// (`TrustRankCopy`). Read from disk once and kept while the file is
/// unchanged (about 2 MB on a 28,000-person map). nil with no Haven, no file
/// yet, or a file that does not check out. Android twin:
/// `service/TrustRankCopyStore.kt`.
actor TrustRankCopyStore {
    static let shared = TrustRankCopyStore()

    private struct Held {
        let path: String
        let modified: Date?
        let size: Int?
        let copy: TrustRankCopy?
    }

    private var held: Held?

    /// The active account's copy.
    @MainActor static func active() async -> TrustRankCopy? {
        await shared.copy(for: ConfigService.shared.activeAccountHexPubkey, in: ConfigService.shared.relayDataDir)
    }

    @MainActor static func copy(for account: String) async -> TrustRankCopy? {
        await shared.copy(for: account, in: ConfigService.shared.relayDataDir)
    }

    /// `dir`: the relay's data folder, where the engine keeps the WoT cache.
    func copy(for account: String, in dir: URL) -> TrustRankCopy? {
        guard account.count == 64 else { return nil }
        let url = dir.appendingPathComponent(TrustRankCopy.fileName(account: account))
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        if let held, held.path == url.path, held.modified == values.contentModificationDate,
           held.size == values.fileSize {
            return held.copy
        }
        let copy = (try? Data(contentsOf: url)).flatMap { TrustRankCopy.parse($0, account: account) }
        held = Held(path: url.path, modified: values.contentModificationDate, size: values.fileSize, copy: copy)
        return copy
    }
}

/// The active account's copy for a view, read again when the account
/// changes. Loading starts when the view is created, not in `.task`: a view
/// that draws nothing until it has the copy never appears, so its `.task`
/// would never run.
@MainActor
final class TrustRankCopyWatch: ObservableObject {
    @Published private(set) var copy: TrustRankCopy?
    private var account: AnyCancellable?
    private var load: Task<Void, Never>?

    init() {
        account = ConfigService.shared.$activeAccountHexPubkey
            .removeDuplicates()
            .sink { [weak self] me in self?.reload(me) }
    }

    private func reload(_ me: String) {
        load?.cancel()
        copy = nil
        load = Task { [weak self] in
            let copy = await TrustRankCopyStore.copy(for: me)
            guard !Task.isCancelled else { return }
            self?.copy = copy
        }
    }
}
