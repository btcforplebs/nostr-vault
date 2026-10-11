import SwiftUI

/// A text field that writes to its binding only when editing ends (Return,
/// focus leaving, or the page closing). For settings the relay reads at
/// start: every write of a half-typed port or domain would otherwise be a
/// saved config, and a saved relay-facing config restarts the relay.
struct CommitOnEndTextField: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var relayManager: RelayProcessManager
    private let title: String
    @Binding private var text: String
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        TextField(title, text: $draft)
            .focused($isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: text) { _, newValue in
                if !isFocused { draft = newValue }
            }
            .onAppear { draft = text }
            .onDisappear {
                // Leaving Settings from this page, SettingsView's own
                // onDisappear may already have saved, and its onChange
                // no longer fires. Save and apply here so the edit isn't lost.
                if commit() {
                    configService.save()
                    relayManager.applySavedConfig(configService.config)
                }
            }
    }

    /// Returns whether the binding was written.
    @discardableResult
    private func commit() -> Bool {
        let changed = draft != text
        if changed { text = draft }
        // The binding may reject or normalise the value (an out-of-range
        // port); show what was actually kept.
        draft = text
        return changed
    }
}
