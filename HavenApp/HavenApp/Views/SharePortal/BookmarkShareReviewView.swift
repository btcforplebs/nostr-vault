import SwiftUI

/// Review a link the share sheet queued for Save for later, then add it to
/// the Bookmarks list, publicly or privately. Nothing is signed until Save.
/// Twin: BookmarkShareReviewContent.kt.
struct BookmarkShareReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var privately = false
    @State private var saving = false
    @State private var message: String?

    private var url: String? { BookmarkShareHandler.url(for: intent) }
    private var activeNpub: String {
        PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
    }
    /// The account the share was for; nil means whichever is active.
    private var wanted: String? { intent.account }
    private var isOnDevice: Bool { wanted.map { config.allAccountNpubs.contains($0) } ?? true }
    private var isActive: Bool { wanted.map { $0 == activeNpub } ?? true }
    private var canSave: Bool { url != nil && isOnDevice && isActive && config.activeAccountCanSign && !saving }

    var body: some View {
        Form {
            if let url {
                Section("Link") {
                    if let title = intent.source.title, !title.isEmpty { Text(title).font(.subheadline) }
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle)
                }
                Section {
                    Picker("Who can see it", selection: $privately) {
                        Text("Public").tag(false)
                        Text("Private").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(privately
                         ? "Only you can read it: it is encrypted to your own key on your Bookmarks list."
                         : "Anyone can see it on your Bookmarks list.")
                }
            } else {
                Section { Text("This share has no web link to save.").foregroundStyle(.secondary) }
            }
            accountSection
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Button(action: save) {
                    HStack {
                        Spacer()
                        if saving { ProgressView() } else { Text("Save for later").font(.headline) }
                        Spacer()
                    }
                }
                .disabled(!canSave)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        let npub = wanted ?? activeNpub
        let name = accountName(npub)
        Section("Saving to") {
            Text(name)
            if !isOnDevice {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if !isActive {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            } else if !config.activeAccountCanSign {
                Text("This account is read-only here.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func accountName(_ npub: String) -> String {
        let profile = Bech32.decode(npub).flatMap { NostrService.shared.profiles[$0.hexString] }
        return profile?.bestName ?? String(npub.prefix(16)) + "…"
    }

    private func save() {
        guard let url else { return }
        saving = true
        message = nil
        let privately = privately
        Task {
            let outcome = await BookmarkShareHandler.save(url, privately: privately)
            saving = false
            switch outcome {
            case .saved(let priv):
                ActionToastManager.shared.show(icon: "bookmark.fill", message: priv ? "Saved privately" : "Saved for later")
                close()
            case .alreadyPublic:
                ActionToastManager.shared.show(icon: "bookmark.fill", message: "Already in your bookmarks")
                close()
            case .alreadyPrivate:
                ActionToastManager.shared.show(icon: "bookmark.fill", message: "Already in your private bookmarks")
                close()
            case .failed(let why):
                message = why
            }
        }
    }
}
