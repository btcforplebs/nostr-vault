import SwiftUI

/// Review a private copy the share sheet queued, then keep it. Nothing is
/// read, sealed or saved until "Save privately".
struct PrivateCopyReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var step: PrivateCopyStore.Step?
    @State private var saved = false
    @State private var error: String?

    private var npub: String { ShareAccountSection.account(for: intent) }
    private var file: NVShareIntent.File? { PrivateCopyStore.file(of: intent) }
    private var page: URL? { PrivateCopyStore.pageURL(of: intent) }
    private var tooBig: Bool { (file?.bytes ?? 0) > PrivateCopyRecord.maxBytes }
    private var canSave: Bool {
        _ = config.config.activeAccountNpub  // re-evaluate on account switch
        return step == nil && !saved && !tooBig && (file != nil || page != nil) && ShareAccountSection.canAct(as: npub)
    }

    var body: some View {
        if saved { done } else { form }
    }

    private var form: some View {
        Form {
            Section("What's kept") {
                if let file {
                    Label(file.name, systemImage: "doc")
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))
                        .font(.footnote).foregroundStyle(.secondary)
                    if tooBig {
                        Text(PrivateCopyStore.SaveError.tooBig.localizedDescription).font(.footnote).foregroundStyle(.orange)
                    }
                } else if let page {
                    if let title = intent.source.title, !title.isEmpty { Text(title).font(.subheadline) }
                    Text(page.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    Text("The page is saved as a PDF, as it looks now.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Nothing to keep: no file or web page came with this share.").foregroundStyle(.secondary)
                }
            }
            ShareAccountSection(npub: npub, title: "Kept for")
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        if let step {
                            ProgressView()
                            Text(label(step)).padding(.leading, 6)
                        } else {
                            Label("Save privately", systemImage: "lock.fill").font(.headline)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSave)
            } footer: {
                Text("Encrypted on this device with a new key. Kept only in your vault, never on outside servers. Only this account can open it.")
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.doc.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Saved privately").font(.headline)
            Text("Encrypted and kept in your vault.").font(.subheadline).foregroundStyle(.secondary)
            NavigationLink("See private copies") { PrivateCopiesView() }
            Button("Done", action: close).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func label(_ step: PrivateCopyStore.Step) -> String {
        switch step {
        case .rendering: return "Saving the page…"
        case .sealing: return "Encrypting…"
        case .saving: return "Keeping it in your vault…"
        }
    }

    private func save() {
        guard let lock = ShareAccountSection.lock(npub) else { return }
        error = nil
        step = .sealing
        Task {
            do {
                try await PrivateCopyStore.save(intent, lockedTo: lock) { step = $0 }
                step = nil
                saved = true
            } catch {
                self.error = error.localizedDescription
                step = nil
            }
        }
    }
}
