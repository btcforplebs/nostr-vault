import SwiftUI

/// Settings › Sync with Mac, whichever form this platform has.
struct MacSyncSettingsPage: View {
    var body: some View {
        #if os(iOS)
        MacRelaySettingsView()
        #else
        MacRelayDomainSettingsView()
        #endif
    }
}
