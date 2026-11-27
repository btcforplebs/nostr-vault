import SwiftUI

/// Settings › Blocked › Clean mode: masks swear words from the built-in list
/// (`CleanMode`) in what this device shows. Local to this device, off by
/// default, never published. Embedded in `BlockedSettingsView`'s form as its
/// own section. Android: CleanModeSetting.kt; web: net/clean-mode.js toggle.
struct CleanModeSettingsView: View {
    @AppStorage(CleanMode.defaultsKey) private var cleanMode = false

    var body: some View {
        Section {
            Toggle("Mask swear words, like f***", isOn: $cleanMode)
        } header: {
            Text("Clean Mode")
        } footer: {
            Text("Shows swear words as their first letter and asterisks in notes, messages, names and notifications on this device. What you write and send isn't changed.")
        }
    }
}
