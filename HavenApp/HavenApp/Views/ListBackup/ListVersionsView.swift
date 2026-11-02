import SwiftUI

/// Every kept version of one list, newest first: which app saved it, when,
/// how big it was and what it changed against the one before, with the wipe
/// flagged. On top, the two ways back explained: tap a version to restore
/// it, or merge old versions into the list now (Logen 2026-11-02). Twin of
/// Android `ListVersionsPage.kt` and web `RecoverListPage.jsx`.
struct ListVersionsView: View {
    let key: ListHistory.Key
    @ObservedObject private var service = ListBackupService.shared
    @State private var restoring: ListVersion?
    @State private var merging = false

    private var versions: [ListVersion] { service.groups[key] ?? [] }
    private var canMerge: Bool { ListVersionMerge.canMerge(key.kind) && versions.count >= 2 }

    var body: some View {
        Form {
            if versions.count >= 2 {
                Section("Bring back an old version") {
                    Text(ListVersionWording.restoreExplainer)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                    if canMerge {
                        Button { merging = true } label: { mergeEntry }
                            .buttonStyle(.plain)
                    }
                }
            }
            Section {
                ForEach(Array(versions.enumerated()), id: \.element.id) { index, version in
                    Button { if index > 0 { restoring = version } } label: { row(version, index: index) }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                }
            } header: {
                Text("Versions")
            } footer: {
                Text("Restoring signs the old version again as a new list. Your vault keeps the one it replaces.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(ListBackupFormat.title(key))
        .sheet(item: $restoring) { old in ListRestoreView(old: old) }
        .sheet(isPresented: $merging) { ListMergeView(key: key) }
    }

    private var mergeEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.appSystem(size: 17, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Merge old versions").foregroundColor(.primary)
                Text(ListVersionWording.mergeExplainer(key.kind))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.appSystem(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func row(_ version: ListVersion, index: Int) -> some View {
        let older = index + 1 < versions.count ? versions[index + 1] : nil
        let wiped = older.map { ListShrinkRule.shrank($0, version) } ?? false
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(ListVersionWording.app(version)), \(ListBackupFormat.date(version.createdAt))")
                    if index == 0 { Text("Now").font(.appCaption).foregroundColor(.secondary) }
                }
                Text(ListVersionWording.detail(version, older: older))
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                if wiped {
                    Label(ListVersionWording.wipedFlag, systemImage: "exclamationmark.triangle.fill")
                        .font(.appCaption.weight(.semibold))
                        .foregroundColor(.orange)
                }
            }
            Spacer()
            if index > 0 {
                Text("Restore").font(.appSystem(size: 13, weight: .semibold)).foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
