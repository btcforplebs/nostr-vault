import SwiftUI

/// Restore one kept version of a list: shows what comes back and what goes,
/// against the newest list fetched when this opens, and publishes only on
/// the tap. Used by the wipe banner and the versions page.
struct ListRestoreView: View {
    let old: ListVersion
    @ObservedObject private var service = ListBackupService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var preview: NostrService.ListRestorePreview?
    @State private var problem: String?
    @State private var working = false
    @State private var done = false

    private var name: String { ListShrinkRule.name(old.kind) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your \(name) from \(ListBackupFormat.date(old.createdAt)), \(ListBackupFormat.count(old)).")
                    if done {
                        Label("Restored. Your vault still keeps the list it replaced.", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.havenOnline)
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    } else if preview == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking your newest \(name)…").foregroundColor(.secondary)
                        }
                    }
                }
                if let preview, !done {
                    changes("Comes back", preview.comeBack)
                    changes("Goes", preview.go)
                    if preview.replacesPrivate {
                        Section {
                            Label("Your private items go back to the ones from \(ListBackupFormat.date(old.createdAt)). Private items added since then are removed.",
                                  systemImage: "lock.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    if preview.comeBack.isEmpty && preview.go.isEmpty {
                        Section { Text(preview.replacesPrivate ? "Same public items as your newest \(name)." : "Same items as your newest \(name).").foregroundColor(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Restore \(name)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "Done" : "Cancel") { dismiss() }
                }
                if !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") { Task { await restore() } }
                            .disabled(preview == nil || working || problem != nil)
                    }
                }
            }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private func changes(_ title: String, _ items: Set<String>) -> some View {
        if !items.isEmpty {
            Section("\(title) (\(items.count))") {
                ForEach(items.sorted().prefix(50), id: \.self) { key in
                    Text(ListHistory.label(key)).font(.appCaption).lineLimit(1).truncationMode(.middle)
                }
                if items.count > 50 {
                    Text("and \(items.count - 50) more").foregroundColor(.secondary)
                }
            }
        }
    }

    private func load() async {
        switch await service.preview(old) {
        case .success(let result): preview = result
        case .failure(let error): problem = error.message
        }
    }

    private func restore() async {
        guard let preview else { return }
        working = true
        defer { working = false }
        if let message = await service.restore(old, preview: preview) {
            problem = message
        } else {
            done = true
        }
    }
}

/// How list versions read on screen.
enum ListBackupFormat {
    static func date(_ createdAt: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(createdAt)).formatted(date: .abbreviated, time: .shortened)
    }

    static func count(_ v: ListVersion) -> String {
        let n = ListShrinkRule.itemCount(v)
        if v.kind == 0 { return n == 1 ? "1 field" : "\(n) fields" }
        let base = n == 1 ? "1 item" : "\(n) items"
        return ListShrinkRule.encryptedKinds.contains(v.kind) && !v.content.isEmpty ? base + " + private items" : base
    }

    static func title(_ key: ListHistory.Key) -> String {
        let name = ListShrinkRule.name(key.kind)
        let titled = name.prefix(1).uppercased() + name.dropFirst()
        return key.d.isEmpty ? titled : "\(titled) “\(key.d)”"
    }
}
