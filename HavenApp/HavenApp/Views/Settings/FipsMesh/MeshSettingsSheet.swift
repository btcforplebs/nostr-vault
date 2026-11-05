import SwiftUI

#if os(iOS)
/// Mesh settings as a sheet, opened from the Profile tab's Mesh button.
struct MeshSettingsSheet: View {
    @EnvironmentObject var configService: ConfigService
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            FipsMeshSettingsView()
                .environmentObject(configService)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onClose)
                            .foregroundColor(.havenPurple)
                    }
                }
        }
    }
}
#endif
