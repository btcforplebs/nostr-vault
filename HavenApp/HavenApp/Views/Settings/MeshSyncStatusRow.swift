#if os(iOS)
// iPhone and iPad only: the Mac stays silent about sync (Logen, 3.3.0).
import SwiftUI

/// Settings › Your Devices › Sync with your vaults: one row per device this
/// one copies from over the mesh, and one Sync now that catches up with
/// each of them in turn, the longest ago first. Hidden until this device
/// has copied from one. Mac and iPhone; Android: MeshSyncStatusRow.kt.
struct MeshSyncStatusSection: View {
    let devices: [MeshDevice]
    @EnvironmentObject var configService: ConfigService
    @ObservedObject private var copy = MeshCopyV2Service.shared

    /// Re-read once a minute so "Last synced 5 min ago" moves on by itself.
    @State private var now = Int(Date().timeIntervalSince1970)
    private static let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        let rows = MeshSyncStatus.rows(devices: devices, sync: copy.syncState, progress: copy.progress, now: now)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { MeshSyncStatusRow(row: $0) }
                Button(MeshSyncStatus.syncNow) { copy.syncNow() }
                    .disabled(!MeshSyncStatus.syncEnabled(setupDone: configService.config.hasCompletedSetup,
                                                          rows: rows, sync: copy.syncState))
            } header: {
                Text(MeshSyncStatus.header)
            } footer: {
                Text(MeshSyncStatus.footer)
            }
            .onReceive(Self.tick) {
                now = Int($0.timeIntervalSince1970)
            }
            .onChange(of: copy.syncState) { _, _ in now = Int(Date().timeIntervalSince1970) }
        }
    }
}

/// One device: its name, when it last synced, and a dot with what its
/// catch-up is doing.
struct MeshSyncStatusRow: View {
    let row: MeshSyncStatus.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.name)
                .font(.appBody)
                .lineLimit(1)
            Text(row.lastLine)
                .font(.appCaption)
                .foregroundColor(.secondary)
            HStack(spacing: 6) {
                if row.state == .syncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                }
                Text(row.stateLine)
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        switch row.state {
        case .failed, .waiting: return .orange
        case .syncing, .upToDate: return .havenOnline
        }
    }
}
#endif
