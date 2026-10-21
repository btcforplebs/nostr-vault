import SwiftUI

// MARK: - Gated (locked) body

/// The body of a gated article: its teaser and a lock card, or the decrypted
/// article when this reader has unlocked it. The app never pays for an
/// article (App Store 3.1.1). A Fanfares article opens here once Fanfares' key
/// server sees the reader's payment; only the Mac links out to Fanfares, since
/// on iOS a link to buy it is steering. See `GatedArticle`.
struct GatedArticleBody: View {
    let note: FeedNote
    let gated: GatedArticle
    var onImageTap: ((URL) -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case checking, locked, unlocked(String), failed(String)
    }
    @State private var phase: Phase = .locked

    var body: some View {
        if let markdown = unlockedMarkdown {
            MarkdownBodyView(markdown: markdown, onImageTap: onImageTap)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                let teaser = GatedArticleTeaser.strip(note.content)
                if !teaser.isEmpty, teaser != note.longFormMetadata.summary {
                    MarkdownBodyView(markdown: teaser, onImageTap: onImageTap)
                }
                lockCard
            }
            // Keyed on the reader too: a stored key belongs to one account.
            .task(id: note.id + nostrService.activeHexPubkey) { await checkAccess(auto: true) }
        }
    }

    private var unlockedMarkdown: String? {
        if case .unlocked(let markdown) = phase { return markdown }
        return GatedArticleService.shared.unlockedBody(note: note, gated: gated)
    }

    private var authorName: String {
        nostrService.profiles[note.pubkey]?.bestName ?? "the author"
    }

    private var fanfaresURL: URL? {
        GatedArticleService.shared.fanfaresURL(note: note, gated: gated)
    }

    private var statusText: String {
        guard gated.isFanfares else { return GatedLockCopy.status(author: authorName) }
        var failure: String?
        if case .failed(let message) = phase { failure = message }
        #if os(macOS)
        return GatedLockCopy.fanfaresStatus(author: authorName, failure: failure)
        #else
        return failure ?? GatedLockCopy.status(author: authorName)
        #endif
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Locked article")
                    .font(.appSystem(size: 16, weight: .bold))
            }

            Text(statusText)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if fanfaresURL != nil {
                #if os(macOS)
                if let url = fanfaresURL {
                    Button {
                        openURL(url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open in Fanfares")
                                .font(.appSystem(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.havenPurple)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                #endif

                Button {
                    Task { await checkAccess(auto: false) }
                } label: {
                    HStack(spacing: 6) {
                        if phase == .checking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.seal")
                        }
                        Text(phase == .checking ? "Checking…" : "Already unlocked?")
                    }
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.havenPurple)
                }
                .buttonStyle(.plain)
                .disabled(phase == .checking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.35), lineWidth: 1)
        )
    }

    /// Asks Fanfares' key server whether this reader has paid. Only Fanfares
    /// articles ask. The check that runs on open (`auto`) asks the signer only
    /// when that's silent (a local key); a remote signer would otherwise
    /// prompt on every view.
    private func checkAccess(auto: Bool) async {
        guard gated.isFanfares, phase != .checking else { return }
        if auto, !GatedArticleService.shared.canCheckSilently { return }
        phase = .checking
        do {
            phase = .unlocked(try await GatedArticleService.shared.open(note: note, gated: gated))
        } catch {
            // Not paid yet is the normal case on open; on a check the reader
            // asked for, say why it didn't open.
            phase = auto ? .locked : .failed(error.localizedDescription)
        }
    }
}
