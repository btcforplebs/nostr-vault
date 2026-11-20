#if os(macOS)
import SwiftUI

/// Run in background (BackgroundMode): the Mac as a vault only. Shown in
/// Settings › Your Vault › Startup and in the menu bar panel.
struct RunInBackgroundToggle: View {
    @ObservedObject private var mode = BackgroundMode.shared
    /// The panel shows the switch without the explanation line.
    var showsDetail = true

    var body: some View {
        Toggle(isOn: Binding(get: { mode.isOn }, set: { mode.set($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run in background")
                if showsDetail {
                    Text("Only the vault runs: your relay, media, mesh and sync. The window closes and the feed and pictures leave memory until you open it again from the menu bar. Turns on Launch at Login.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityHint("Runs only the vault and closes the window")
    }
}
#endif
