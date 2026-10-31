import SwiftUI

/// The one FIPS Mesh link left on Media Servers.
struct FipsMeshLinkRow: View {
    var body: some View {
        #if os(iOS)
        NavigationLink {
            FipsMeshSettingsView()
        } label: {
            label
        }
        #else
        Button {
            NotificationCenter.default.post(name: .havenOpenFipsMeshSettings, object: nil)
        } label: {
            label
        }
        .buttonStyle(.plain)
        #endif
    }

    private var label: some View {
        Label("Your mesh address, devices and sharing: Mesh", systemImage: "point.3.filled.connected.trianglepath.dotted")
            .font(.appCaption)
            .foregroundColor(.havenPurple)
    }
}
