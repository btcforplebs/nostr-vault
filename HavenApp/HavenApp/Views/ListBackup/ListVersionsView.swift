import SwiftUI

/// Every kept version of one list, newest first, with what changed against
/// the newest; tap one to restore it. Twin of Android `ListVersionsScreen.kt`.
struct ListVersionsView: View {
    let key: ListHistory.Key
    @ObservedObject private var service = ListBackupService.shared
    @State private var restoring: ListVersion?

    private var versions: [ListVersion] { service.groups[key] ?? [] }

    var body: some View {
        Form {
            Section {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    Button { if index > 0 { restoring = version } } label: { row(version, index: index) }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                }
            } footer: {
                Text("Restoring signs the old version again as a new list. Your vault keeps the one it replaces.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(ListBackupFormat.title(key))
        .sheet(item: $restoring) { old in ListRestoreView(old: old) }
    }

    private func row(_ version: ListVersion, index: Int) -> some View {
        let newest = versions.first
        let diff = newest.map { ListHistory.diff(restoring: version, over: $0) }
        let wiped = index + 1 < versions.count && ListShrinkRule.shrank(versions[index + 1], version)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ListBackupFormat.date(version.createdAt))
                    if index == 0 { Text("Newest").font(.appCaption).foregroundColor(.secondary) }
                    if wiped {
                        Text("Wipe").font(.appCaption).foregroundColor(.orange)
                    }
                }
                Text(index == 0 ? ListBackupFormat.count(version)
                     : "\(ListBackupFormat.count(version)) · \(diff?.comeBack.count ?? 0) not in newest, \(diff?.go.count ?? 0) added since")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if index > 0 {
                Text("Restore").font(.appSystem(size: 13, weight: .semibold)).foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
