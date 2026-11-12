import SwiftUI

#if os(iOS)
/// Your Devices › This phone: Mobile vault mode, the same switch as Mesh ›
/// Share With Others, worded for someone who has never heard of the mesh.
/// What it has served stays on the Mesh page.
struct YourDevicesThisPhoneSection: View {
    @ObservedObject private var mesh = FipsMeshService.shared
    @EnvironmentObject private var configService: ConfigService

    /// Keep a full copy (multi-Mac rules §3): on unless turned off, and
    /// locked on in mobile vault mode.
    private var fullCopy: Binding<Bool> {
        Binding(
            get: { YourDevicesLogic.keepsFullCopy(isDesktop: false, mobileVault: mesh.kioskActive,
                                                  stored: configService.config.keepFullCopy) },
            set: { on in
                configService.config.keepFullCopy = on
                configService.save()
            }
        )
    }

    private var wifiOnly: Binding<Bool> {
        Binding(
            get: { configService.config.fullCopyWifiOnly != false },
            set: { on in
                configService.config.fullCopyWifiOnly = on
                configService.save()
            }
        )
    }

    var body: some View {
        Section {
            Toggle(isOn: fullCopy) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keep a full copy on this phone").font(.appBody)
                    Text(mesh.kioskActive ? YourDevicesLogic.fullCopyLockedLine
                         : "Every photo and file from your other devices shows up here. Off: notes only, files when you open them.")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.havenPurple)
            .disabled(YourDevicesLogic.fullCopyLocked(mobileVault: mesh.kioskActive))
            if fullCopy.wrappedValue {
                Toggle(isOn: wifiOnly) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wi-Fi only").font(.appBody)
                        Text("Catching up on files waits for Wi-Fi. What you add here always goes out right away.")
                            .font(.appCaption)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(Color.havenPurple)
            }
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
