import SwiftUI

/// Review a highlight the share sheet queued, then publish it (kind 9802).
/// The passage and comment are editable once more; nothing is signed until
/// Publish.
struct HighlightReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var passage = ""
    @State private var comment = ""
    @State private var pageLink = ""
    @State private var started = false
    @State private var publishing = false
    @State private var error: String?

    private var npub: String { HighlightShareHandler.account(for: intent) }
    private var activeNpub: String {
        PostingAccount.resolve(active: config.config.activeAccountNpub, owner: config.config.ownerNpub)
    }
    private var isOnDevice: Bool { config.allAccountNpubs.contains(npub) }
    private var isActive: Bool { npub == activeNpub }
    /// No page came with it (Safari's text-menu Share… sends only the words): the link is typed here or in the sheet.
    private var arrivedWithoutLink: Bool { intent.source.url == nil }
    private var linkCheck: HighlightPageLink.Check { HighlightPageLink.check(pageLink) }
    private var canPublish: Bool {
        isOnDevice && isActive && !publishing && !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && linkCheck != .notALink
    }

    var body: some View {
        Form {
            if let url = intent.source.url {
                Section("From") {
                    if let title = intent.source.title, !title.isEmpty { Text(title).font(.subheadline) }
                    Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            Section {
                TextEditor(text: $passage)
                    .font(.appSystem(size: 16))
                    .frame(minHeight: 140)
            } header: {
                Text("Highlight")
            } footer: {
                Text("Delete what you don't want to keep.")
            }
            Section("Your thoughts (optional)") {
                TextField("Add a comment", text: $comment, axis: .vertical)
                    .lineLimit(2...5)
            }
            if arrivedWithoutLink {
                Section {
                    TextField(HighlightPageLink.placeholder, text: $pageLink)
                        .webAddressEntry()
                } header: {
                    Text(HighlightPageLink.label)
                } footer: {
                    Text(linkCheck == .notALink ? HighlightPageLink.problem : HighlightPageLink.hint)
                        .foregroundStyle(linkCheck == .notALink ? Color.red : Color.secondary)
                }
            }
            accountSection
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button {
                    publish()
                } label: {
                    HStack {
                        Spacer()
                        if publishing { ProgressView() } else { Text("Publish").font(.headline) }
                        Spacer()
                    }
                }
                .disabled(!canPublish)
            } footer: {
                Text("Highlights are public.")
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            passage = intent.form["passage"] ?? intent.source.selection ?? ""
            comment = intent.form["comment"] ?? ""
            pageLink = intent.form["pageLink"] ?? ""
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        let name = accountName(npub)
        Section("Posting as") {
            Text(name)
            if !isOnDevice {
                Text("That account isn't on this device any more.").font(.footnote).foregroundStyle(.secondary)
            } else if !isActive {
                Button("Switch to \(name)") { config.switchActiveAccount(to: npub) }
            }
        }
    }

    private func accountName(_ npub: String) -> String {
        let profile = Bech32.decode(npub).flatMap { NostrService.shared.profiles[$0.hexString] }
        return profile?.bestName ?? String(npub.prefix(16)) + "…"
    }

    private func publish() {
        publishing = true
        error = nil
        let passage = passage
        let comment = comment
        let url = intent.source.url ?? HighlightPageLink.link(pageLink)
        Task {
            do {
                try await HighlightShareHandler.publish(intent, url: url, passage: passage, comment: comment)
                close()
            } catch {
                self.error = error.localizedDescription
                publishing = false
            }
        }
    }
}

private extension View {
    /// A URL keyboard with no capitals or autocorrect on iPhone and iPad; the Mac has neither.
    @ViewBuilder func webAddressEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}
