import SwiftUI
import CoreImage.CIFilterBuiltins

extension WalletLightningTab {
    // MARK: - History

    var historyCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("HISTORY")
                    .font(.appSystem(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if isLoadingHistory {
                    ProgressView().controlSize(.small)
                } else if !historyUnsupported {
                    Button(action: { loadHistory(reset: true) }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.appSystem(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }

            if historyUnsupported {
                Text("Your wallet doesn't share its payment history with apps. If it supports it, reconnect the wallet with \"transaction history\" (list transactions) allowed.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let historyError, transactions.isEmpty {
                Text(historyError)
                    .font(.appCaption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if transactions.isEmpty && !isLoadingHistory {
                Text("No payments yet.")
                    .font(.appCaption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(transactions) { tx in
                        transactionRow(tx)
                        if tx.id != transactions.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
                if canLoadMoreHistory {
                    Button(action: { loadHistory(reset: false) }) {
                        Text("Show more")
                            .font(.appSystem(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoadingHistory)
                }
            }
        }
        .padding(16)
        .background(Color.platformControlBackground.opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.platformSeparator.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }

    /// A zap row opens the zapped post; anything else is just a row.
    @ViewBuilder
    private func transactionRow(_ tx: WalletTransaction) -> some View {
        if let postId = zapDetails[tx.id]?.postId, let post = zapPosts[postId] {
            NavigationLink(value: post) {
                transactionRowContent(tx)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            transactionRowContent(tx)
        }
    }

    private func transactionRowContent(_ tx: WalletTransaction) -> some View {
        let incoming = tx.direction == .incoming
        let zap = zapDetails[tx.id]
        let person = zap?.counterparty(me: nostrService.activeHexPubkey, direction: tx.direction)
        return HStack(spacing: 12) {
            if let person {
                AvatarView(url: nostrService.profiles[person]?.pictureURL, pubkey: person, size: 28)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Circle().fill(Color.orange))
                            .offset(x: 3, y: 3)
                    }
            } else {
                Image(systemName: zap != nil ? "bolt.fill" : (incoming ? "arrow.down.left" : "arrow.up.right"))
                    .font(.appSystem(size: 13, weight: .bold))
                    .foregroundColor(zap != nil ? .orange : (incoming ? .green : .orange))
                    .frame(width: 28, height: 28)
                    .background((zap != nil ? Color.orange : (incoming ? Color.green : Color.orange)).opacity(0.12))
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(transactionTitle(tx, zap: zap, person: person))
                    .font(.appSystem(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let line = zapContextLine(zap, incoming: incoming) {
                    Text(line)
                        .font(.appCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Text(transactionSubtitle(tx))
                    .font(.appCaption)
                    .foregroundColor(tx.state == .failed || tx.state == .expired ? .red : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(incoming ? "+" : "−")\(formatSats(tx.amountSats))")
                .font(.appSystem(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(tx.state == .settled ? (incoming ? .green : .primary) : .secondary)
                .strikethrough(tx.state == .failed || tx.state == .expired)
        }
        .padding(.vertical, 8)
    }

    private func transactionTitle(_ tx: WalletTransaction, zap: ZapDetail?, person: String?) -> String {
        let incoming = tx.direction == .incoming
        guard let zap else { return tx.description ?? (incoming ? "Received" : "Sent") }
        if incoming && zap.isAnonymous { return "Anonymous zap" }
        guard let person else { return incoming ? "Zap received" : "Zap sent" }
        let name = nostrService.profiles[person]?.bestName ?? ("npub…" + String(person.suffix(6)))
        return incoming ? "Zap from \(name)" : "Zap to \(name)"
    }

    /// What the zap was for: the sender's comment, else the start of the post.
    private func zapContextLine(_ zap: ZapDetail?, incoming: Bool) -> String? {
        guard let zap else { return nil }
        if let comment = zap.comment { return "\u{201C}\(comment)\u{201D}" }
        if let id = zap.postId, let post = zapPosts[id] {
            let text = post.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "on a post" : "on: \(text)"
        }
        return zap.postId != nil ? "on a post" : (incoming ? "on your profile" : "on their profile")
    }

    /// Looks up who each zap on this page came from, without holding up the list.
    private func resolveZaps(_ page: [WalletTransaction]) {
        let me = nostrService.activeHexPubkey
        Task {
            let found = await ZapHistoryService.lookup(for: page, me: me)
            zapDetails.merge(found.details) { _, new in new }
            zapPosts.merge(found.posts) { _, new in new }
        }
    }

    private func transactionSubtitle(_ tx: WalletTransaction) -> String {
        var parts = [tx.createdAt.formatted(.relative(presentation: .named))]
        switch tx.state {
        case .pending: parts.append("pending")
        case .failed: parts.append("failed")
        case .expired: parts.append("expired")
        case .settled: break
        }
        if tx.direction == .outgoing && tx.feeSats > 0 {
            parts.append("fee \(formatSats(tx.feeSats))")
        }
        return parts.joined(separator: " · ")
    }

    func loadHistory(reset: Bool) {
        guard !isLoadingHistory else {
            // A payment just finished while a page was loading: refresh after.
            if reset { historyRefreshPending = true }
            return
        }
        isLoadingHistory = true
        historyError = nil
        let offset = reset ? 0 : transactions.count
        Task {
            do {
                let page = try await NWCService.listTransactions(limit: Self.historyPageSize, offset: offset)
                transactions = reset ? page : WalletTransaction.merge(transactions, page)
                resolveZaps(page)
                canLoadMoreHistory = page.count >= Self.historyPageSize
                historyUnsupported = false
            } catch let err as NWCService.WalletError where err.isUnsupported {
                historyUnsupported = true
            } catch {
                historyError = "Couldn't load history: \(error.localizedDescription)"
            }
            isLoadingHistory = false
            if historyRefreshPending {
                historyRefreshPending = false
                loadHistory(reset: true)
            }
        }
    }
}
