import SwiftUI

#if os(iOS)
/// Your Devices › This phone: Mobile vault mode, the same switch as Mesh ›
/// Share With Others, worded for someone who has never heard of the mesh.
/// What it has served stays on the Mesh page.
struct YourDevicesThisPhoneSection: View {
    @ObservedObject private var mesh = FipsMeshService.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { mesh.kioskActive || mesh.starting },
                set: { on in on ? mesh.startKiosk() : mesh.stopKiosk() }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use this phone as an always-on vault").font(.appBody)
                    Text("Mobile vault mode: for a spare phone on a charger")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.havenPurple)
            if let until = mesh.pausedUntil, mesh.kioskActive {
                Text("Paused for others until \(until.formatted(date: .abbreviated, time: .shortened)). Your own devices still reach this vault.")
                    .font(.appCaption)
                    .foregroundColor(.orange)
            }
            if let error = mesh.lastError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }
        } header: {
            Text("This phone")
        } footer: {
            // The iPhone's power notice; Android's is worded for the background (YourDevicesRules.POWER_NOTICE).
            Text("Leave this phone on a charger with the app open: it keeps the screen on. Leaving the app pauses it; it turns on again when you come back. Your devices reach it in full.")
        }
    }
}
#endif
