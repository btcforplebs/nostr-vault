import SwiftUI

// MARK: - Gated (zap-to-unlock) body

/// The body of a gated article: its teaser and a lock panel until the reader
/// has paid, then the decrypted article. See `GatedArticle`.
struct GatedArticleBody: View {
    let note: FeedNote
    let gated: GatedArticle
    var onImageTap: ((URL) -> Void)? = nil
    @EnvironmentObject var nostrService: NostrService
    @Environment(\.openURL) private var openURL

    private enum Phase: Equatable {
        case checking, locked, paying, waiting, unlocked(String), failed(String)
    }
    @State private var phase: Phase = .checking
    #if !os(iOS)
    @State private var confirming = false
    #endif
    /// Shares of the price not yet paid. Fewer than all means money may have
    /// moved already: the button then pays only what is left, or just
    /// re-checks for the key, and never pays the same share twice.
    @State private var unpaid: [GatedArticle.Share] = []

    var body: some View {
        if case .unlocked(let markdown) = phase {
            MarkdownBodyView(markdown: markdown, onImageTap: onImageTap)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                let teaser = GatedArticleTeaser.strip(note.content)
                if !teaser.isEmpty, teaser != note.longFormMetadata.summary {
                    MarkdownBodyView(markdown: teaser, onImageTap: onImageTap)
                }
                lockPanel
            }
            // Keyed on the reader too: the stored key and payments belong to
            // one account.
            .task(id: note.id + nostrService.activeHexPubkey) { await checkAccess(auto: true) }
        }
    }

    private var authorName: String {
        nostrService.profiles[note.pubkey]?.bestName ?? "the author"
    }

    private var paid: Bool { unpaid.count < gated.shares.count }
    private var dueSats: Int { unpaid.reduce(0) { $0 + $1.sats } }

    /// iOS never pays to unlock: that is buying digital content (App Store
    /// 3.1.1), and no opt-in changes that. It still opens an article paid for
    /// on the web or in another client, since the key server only checks the
    /// zap receipt.
    private var paysHere: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    private var copy: GatedLockCopy { GatedLockCopy(paysHere: paysHere) }

    /// The author's own link to read or buy the article; never on iOS.
    private var webURL: URL? {
        copy.webLink(authorLink: GatedArticleTeaser.unlockURL(note.content))
    }

    private var lockPanel: some View {
        #if os(iOS)
        lockCard
        #else
        lockCard
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button("Zap \(dueSats) sats") { Task { await pay() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your zap unlocks the full article.")
            }
        #endif
    }

    private var lockCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Locked article")
                    .font(.appSystem(size: 16, weight: .bold))
                Spacer(minLength: 0)
                if copy.showsPrice {
                    Text("\(gated.priceSats) sats")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.havenPurplePale)
                        .foregroundColor(.havenPurple)
                        .clipShape(Capsule())
                }
            }

            Text(statusText)
                .font(.appSystem(size: 14))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Re-checking for a key already paid for shows everywhere.
            if paysHere || (paid && unpaid.isEmpty) {
                Button {
                    if paid && unpaid.isEmpty {
                        Task { await waitForKey() }
                    } else {
                        #if !os(iOS)
                        confirming = true
                        #endif
                    }
                } label: {
                    HStack(spacing: 8) {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: paid && unpaid.isEmpty ? "arrow.clockwise" : "bolt.fill")
                        }
                        Text(busy ? busyLabel : buttonLabel)
                            .font(.appSystem(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.havenPurple.opacity(busy ? 0.6 : 1))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }

            HStack(spacing: 16) {
                if phase == .locked, !paid || (!paysHere && !unpaid.isEmpty) {
                    Button {
                        Task { await checkAccess(auto: false) }
                    } label: {
                        Label("Already paid?", systemImage: "checkmark.seal")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
                if let web = webURL {
                    Button {
                        openURL(web)
                    } label: {
                        Label("Open on \(web.host ?? "the web")", systemImage: "safari")
                            .font(.appSystem(size: 13, weight: .medium))
                            .foregroundColor(.havenPurple)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .background(Color.controlBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.havenPurple.opacity(0.35), lineWidth: 1)
        )
    }

    private var confirmTitle: String {
        gated.shares.count == 1 ? "Zap \(dueSats) sats to \(authorName)?" : "Zap \(dueSats) sats to unlock?"
    }

    private var buttonLabel: String {
        if !paid { return "Zap \(gated.priceSats) sats to unlock" }
        return unpaid.isEmpty ? "Check again" : "Zap the remaining \(dueSats) sats"
    }

    private var busy: Bool { phase == .checking || phase == .paying || phase == .waiting }

    private var busyLabel: String {
        switch phase {
        case .paying: return "Zapping…"
        case .waiting: return "Unlocking…"
        default: return "Checking…"
        }
    }

    private var statusText: String {
        var failure: String?
        if case .failed(let message) = phase { failure = message }
        return copy.status(author: authorName, priceSats: gated.priceSats, paid: paid,
                           fullyPaid: paid && unpaid.isEmpty, failure: failure, waiting: phase == .waiting)
    }

    /// - Parameter auto: the check that runs on open. It asks the signer only
    ///   when that's silent (a local key) or money has already moved — a
    ///   remote signer would otherwise prompt on every view.
    private func checkAccess(auto: Bool) async {
        // A payment in flight owns the phase; a re-run of this task (the row
        // scrolled away and back) must not hand the pay button back.
        guard phase != .paying, phase != .waiting else { return }
        unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
        if auto, !paid, !GatedArticleService.shared.canCheckSilently {
            phase = .locked
            return
        }
        phase = .checking
        do {
            phase = .unlocked(try await GatedArticleService.shared.open(note: note, gated: gated))
        } catch {
            guard phase == .checking else { return }
            // Not paid yet is the normal case; anything else still leaves the
            // way to pay open rather than a dead end.
            phase = .locked
        }
    }

    #if !os(iOS)
    private func pay() async {
        guard !busy else { return }
        phase = .paying
        do {
            try await GatedArticleService.shared.pay(note: note, gated: gated)
        } catch {
            unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
            phase = .failed(paid
                ? "The zap may not have gone through (\(error.localizedDescription)). Check your wallet before paying again — tap Check again if it did."
                : error.localizedDescription)
            return
        }
        unpaid = GatedArticleService.shared.unpaidShares(note: note, gated: gated)
        await waitForKey()
    }
    #endif

    private func waitForKey() async {
        phase = .waiting
        do {
            phase = .unlocked(try await GatedArticleService.shared.waitForKey(note: note, gated: gated))
        } catch GatedArticleService.UnlockError.notPaid {
            phase = .failed("Your zap went through, but the key server hasn't seen the receipt yet. Tap Check again in a minute. It won't charge you again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
