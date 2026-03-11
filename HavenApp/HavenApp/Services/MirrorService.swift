import Foundation
import Combine

/// Service that mirrors owner media from external Blossom servers to local storage.
///
/// Follows the same singleton pattern as MacRelaySyncService. Provides published
/// state for UI observation in RelayStatusSheet and SettingsView.
@MainActor
class MirrorService: ObservableObject {
    static let shared = MirrorService()

    // MARK: - Published State
    enum MirrorState: Equatable {
        case idle
        case mirroring
        case complete
    }

    @Published var state: MirrorState = .idle
    @Published var progress: (completed: Int, total: Int)?
    @Published var lastResult: String = ""
    @Published var lastMirrorDate: Date?

    // MARK: - Public API

    /// Run mirror operation using provided services.
    func runMirror(configService: ConfigService, nostrService: NostrService) {
        guard state != .mirroring else { return }

        state = .mirroring
        progress = nil

        Task {
            let service = BlossomService(configService: configService, nostrService: nostrService)
            var totalCount = 0

            // 1. Mirror from configured Blossom mirrors (BUD-04 /list endpoint)
            if !configService.config.blossomMirrors.isEmpty {
                let count = await service.mirrorAllFromExternal { completed, total in
                    Task { @MainActor in
                        self.progress = (completed, total)
                    }
                }
                totalCount += count
            }

            // 2. Mirror from note media URLs (handles any server)
            let noteMedia = nostrService.noteMedia
            let noteCount = await service.mirrorFromNoteMedia(noteMedia) { completed, total in
                Task { @MainActor in
                    self.progress = (completed, total)
                }
            }
            totalCount += noteCount

            // Update final state
            state = .complete
            progress = nil
            lastMirrorDate = Date()
            lastResult = totalCount > 0 ? "Mirrored \(totalCount) files" : "All media already mirrored"

            // Reset to idle after delay
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if state == .complete {
                state = .idle
            }
        }
    }
}
