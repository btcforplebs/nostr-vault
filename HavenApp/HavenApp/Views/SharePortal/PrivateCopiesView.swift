import SwiftUI
import QuickLook

/// The active account's private copies, from this device's vault. With a
/// remote signer the records are opened only when asked, so opening the
/// list doesn't send every key to the signer.
struct PrivateCopiesView: View {
    @ObservedObject private var config = ConfigService.shared
    @State private var items: [PrivateCopyItem]?
    @State private var failed = false
    @State private var busy: String?
    @State private var preview: URL?
    @State private var error: String?
    @State private var confirmDelete: PrivateCopyItem?

    private var hex: String { NostrService.shared.activeHexPubkey }

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if let items {
                if items.isEmpty {
                    Text(failed ? "Your vault didn't answer. Pull to try again." : "No private copies yet. Share a file or a page to Nostr Vault and pick Keep a private copy.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in row(item) }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Private copies")
        .refreshable { await load() }
        .task(id: hex) { await load() }
        .quickLookPreview($preview)
        .onChange(of: preview) { old, new in
            if new == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
        }
        .confirmationDialog("Delete this private copy?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let item = confirmDelete { delete(item) } }
        } message: {
            Text("The encrypted file and its key are removed from your vault. This can't be undone.")
        }
    }

    private func row(_ item: PrivateCopyItem) -> some View {
        Button { open(item) } label: {
            HStack {
                Image(systemName: "lock.doc").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.record.map { $0.title?.isEmpty == false ? $0.title! : $0.name } ?? "Private copy")
                        .lineLimit(1)
                    Text(subtitle(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if busy == item.id { ProgressView() }
            }
        }
        .disabled(busy != nil)
        .swipeActions {
            if item.record != nil {
                Button("Delete", role: .destructive) { confirmDelete = item }
            }
        }
    }

    private func subtitle(_ item: PrivateCopyItem) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.savedAt)).formatted(date: .abbreviated, time: .shortened)
        guard let r = item.record else { return "\(date) · tap to unlock" }
        return "\(date) · \(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file))"
    }

    private func load() async {
        let me = hex
        guard let found = await PrivateCopyStore.list(for: me) else {
            failed = true
            items = items ?? []
            return
        }
        failed = false
        var out = found
        // A local key reads every record now; a remote signer waits for a tap.
        if !PrivateCopyStore.usesRemoteSigner {
            for i in out.indices { out[i].record = await PrivateCopyStore.readRecord(out[i], me: me) }
        }
        guard me == hex else { return }
        items = out
    }

    private func open(_ item: PrivateCopyItem) {
        busy = item.id
        error = nil
        let me = hex
        Task {
            defer { busy = nil }
            var record = item.record
            if record == nil {
                record = await PrivateCopyStore.readRecord(item, me: me)
                guard let record, me == hex else { error = "Couldn't unlock that copy with this account's key."; return }
                if let i = items?.firstIndex(where: { $0.id == item.id }) { items?[i].record = record }
            }
            guard let record else { return }
            do {
                preview = try await PrivateCopyStore.open(record)
            } catch {
                self.error = "Couldn't open it: the encrypted file isn't in this device's vault, or it changed."
            }
        }
    }

    private func delete(_ item: PrivateCopyItem) {
        let lock = ModePostPublisher.lockAccount(configService: config)
        guard !lock.hex.isEmpty else { return }
        busy = item.id
        Task {
            defer { busy = nil }
            do {
                try await PrivateCopyStore.delete(item, lockedTo: lock)
                items?.removeAll { $0.id == item.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
