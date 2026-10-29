import SwiftUI

#if os(iOS)
/// FIPS Mesh → Share With Others: kiosk mode (this vault on the mesh while the
/// app stays open), what it has served, and where posted photos go. No
/// "Pause after" limit: kiosk mode runs the engine for My Devices, which
/// ignores one (own devices uncapped, strangers on fixed caps; #1023).
/// No listing switch: a phone's own mesh npub is never put in the 10063; the
/// Mac's photo node is listed on its own (PhotoNode, Logen 2026-10-21).
struct FipsMeshShareSection: View {
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var mesh = FipsMeshService.shared

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { mesh.kioskActive || mesh.starting },
                set: { on in on ? mesh.startKiosk() : mesh.stopKiosk() }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kiosk mode").font(.appBody)
                    Text("Share this vault on the mesh while the app stays open")
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                }
            }
            .tint(Color.havenPurple)

            if mesh.kioskActive, let status = mesh.status {
                kioskStatus(status)
            }
            if let error = mesh.lastError {
                Text(error)
                    .font(.appCaption)
                    .foregroundColor(.red)
            }

            Picker("Photos go to", selection: $configService.config.photoDestination) {
                ForEach(MeshPhotoDestination.allCases) { destination in
                    Text(destination.label).tag(destination)
                }
            }
        } header: {
            Text("Share With Others")
        } footer: {
            Text("Kiosk mode keeps the screen on. The devices in My Devices reach this vault in full. Anyone else on the mesh can read only the photos in your posts: 1 MB/s for all of them together, at most 1 GB a day (then they wait until the next day), and 256 MB each. Leaving the app pauses kiosk mode, and it turns on again when you come back.")
        }
    }

    @ViewBuilder
    private func kioskStatus(_ status: FipsMeshService.Status) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(!status.running ? Color.gray : mesh.pausedUntil == nil ? Color.havenOnline : Color.orange)
                .frame(width: 8, height: 8)
            Text(statusText(status))
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        if let until = mesh.pausedUntil {
            Text("Paused for others: the mesh downloaded today's limit. Your own devices still reach this vault. Others can read again \(until.formatted(date: .abbreviated, time: .shortened)).")
                .font(.appCaption)
                .foregroundColor(.orange)
        }
    }

    private func statusText(_ status: FipsMeshService.Status) -> String {
        guard status.running else { return "Mesh stopped" }
        guard mesh.pausedUntil == nil else { return "Sharing paused" }
        guard let counters = status.counters else { return "Sharing" }
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(counters.served_tx), countStyle: .file)
        return "Sharing · served \(counters.served_total) requests, \(bytes)"
    }
}
#endif
