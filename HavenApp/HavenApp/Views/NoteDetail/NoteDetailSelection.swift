import SwiftUI
import Combine

// MARK: - Note Detail Selection

/// Selection model for the iPad two-pane note layout.
///
/// When a `NoteDetailSelection` is present in the environment, note rows select
/// into a sibling detail pane instead of pushing a destination over the whole
/// pane (or presenting a full-screen sheet). Views that can open a note check
/// for one and fall back to their existing push/sheet behaviour when it is
/// absent — which is always the case on iPhone and on macOS.
final class NoteDetailSelection: ObservableObject {
    /// Selected note, when the caller already holds the decoded event.
    @Published var note: FeedNote?
    /// Selected note id, for callers that only know the id and need a lookup.
    @Published var noteId: String?

    var isEmpty: Bool { note == nil && noteId == nil }

    func select(_ note: FeedNote) {
        noteId = nil
        self.note = note
    }

    func select(id: String) {
        note = nil
        noteId = id
    }

    func clear() {
        note = nil
        noteId = nil
    }
}

private struct NoteDetailSelectionKey: EnvironmentKey {
    static let defaultValue: NoteDetailSelection? = nil
}

extension EnvironmentValues {
    var noteDetailSelection: NoteDetailSelection? {
        get { self[NoteDetailSelectionKey.self] }
        set { self[NoteDetailSelectionKey.self] = newValue }
    }
}
