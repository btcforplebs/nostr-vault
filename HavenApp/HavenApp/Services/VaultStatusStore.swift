import Foundation

#if os(macOS)

/// The Mac's own desktop Vault status (`VaultStatusC`), read every few
/// seconds while a status card is on screen and never otherwise. The read
/// is small files plus, once per new ranking, one decode of the result
/// file, so it runs off the main thread.
@MainActor
final class VaultStatusStore: ObservableObject {
    static let shared = VaultStatusStore()

    @Published private(set) var status: VaultStatus?

    private var watchers = 0
    private var timer: Timer?
    private var reading = false
    static let every: TimeInterval = 5

    /// A card appeared: read now and keep reading until the last one goes.
    func watch() {
        watchers += 1
        guard watchers == 1 else { return }
        read()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func read() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            var next: VaultStatus?
            if let pointer = VaultStatusC() {
                next = VaultStatus.decode(Data(String(cString: pointer).utf8))
                free(pointer)
            }
            Task { @MainActor in
                self.reading = false
                if let next, next != self.status { self.status = next }
            }
        }
    }
}

#endif
