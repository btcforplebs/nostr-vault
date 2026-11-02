import SwiftUI

/// List backups: every list the vault keeps old versions of for the active
/// account, one row each. Follows also keep their on-device snapshots in
/// Following Backup. Twin of Android `ListBackupScreen.kt`.
struct ListBackupView: View {
    @ObservedObject private var service = ListBackupService.shared
    @ObservedObject private var config = ConfigService.shared

    var body: some View {
        Form {
            Section {
                Text("Your vault keeps the last 20 versions of each of your lists, and the one from before a wipe. Pick a list to see its versions and restore one.")
                    .font(.appSubheadline)
                    .foregroundColor(.secondary)
            }
            if service.groups.isEmpty {
                Section {
                    switch service.state {
                    case .unavailable:
                        Text("Your vault didn't answer. Make sure it is running, then pull to refresh.").foregroundColor(.secondary)
                    case .loaded:
                        Text("No list versions kept yet. They are kept from the next time a list changes.").foregroundColor(.secondary)
                    case .idle, .loading:
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your vault…") }
                    }
                }
            } else {
                Section("Lists") {
                    ForEach(service.keys, id: \.self) { key in
                        NavigationLink(destination: ListVersionsView(key: key)) { row(key) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .refreshable { await service.load() }
        .task(id: config.config.activeAccountNpub) { await service.load() }
    }

    private func row(_ key: ListHistory.Key) -> some View {
        let versions = service.groups[key] ?? []
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ListBackupFormat.title(key))
                if ListHistory.latestWipe(versions) != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        .accessibilityLabel("Wiped")
                }
            }
            Text("\(versions.count) \(versions.count == 1 ? "version" : "versions")" +
                 (versions.first.map { ", last changed \(ListBackupFormat.date($0.createdAt))" } ?? ""))
                .font(.appCaption)
                .foregroundColor(.secondary)
        }
    }
}
