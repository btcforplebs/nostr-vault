import SwiftUI
import Combine

extension NoteDetailView {
    // MARK: - Rich Engagement Computations

    private var groupedReactions: [(emoji: String, count: Int, reactorPubkeys: [String])] {
        if configService.config.zapsOnlyMode { return [] }
        let reactions = detailedReactions.map { (content: $0.content, pubkey: $0.pubkey, createdAt: $0.created_at) }
        return ReactionGrouping.groups(reactions).map { (emoji: $0.emoji, count: $0.count, reactorPubkeys: $0.reactorPubkeys) }
    }

    struct ZapDetail: Hashable {
        let id: String
        let zapperPubkey: String
        let amountSats: Int64
        let comment: String
    }

    var parsedZaps: [ZapDetail] {
        var list: [ZapDetail] = []
        for zap in detailedZaps {
            guard let descJson = zap.tags.first(where: { $0.count >= 2 && $0[0] == "description" })?[1],
                  let descData = descJson.data(using: .utf8),
                  let zapReq = try? JSONSerialization.jsonObject(with: descData) as? [String: Any],
                  let senderPubkey = zapReq["pubkey"] as? String else { continue }
            
            // The request's `amount` tag is optional (NIP-57); the paid invoice is not.
            let amountSats = Int64(LiveChat.zapAmountSats(receiptTags: zap.tags,
                                                             requestTags: zapReq["tags"] as? [[String]] ?? []))
            let comment = zapReq["content"] as? String ?? ""
            list.append(ZapDetail(id: zap.id, zapperPubkey: senderPubkey, amountSats: amountSats, comment: comment))
        }
        return list.sorted { $0.amountSats > $1.amountSats }
    }

    private var totalZappedSats: Int64 {
        parsedZaps.reduce(0) { $0 + $1.amountSats }
    }

    var reactorsMapped: [(pubkey: String, emoji: String)] {
        detailedReactions.map { (pubkey: $0.pubkey, emoji: ($0.content == "+" || $0.content.isEmpty) ? "❤️" : $0.content) }
    }

    var repostersMapped: [String] {
        Array(Set(detailedReposts.map { $0.pubkey }))
    }

    // MARK: - Engagement Panel View

    @ViewBuilder
    var engagementDetailSection: some View {
        // Thin separator between note content and engagement
        Rectangle()
            .fill(Color.havenPurple.opacity(0.15))
            .frame(height: 0.5)
            .padding(.top, 10)

        // Compact inline engagement row
        HStack(spacing: 12) {
            // Reactions — tappable pill list
            if !groupedReactions.isEmpty {
                Button {
                    showingReactorsSheet = true
                } label: {
                    HStack(spacing: 4) {
                        ForEach(groupedReactions.prefix(4), id: \.emoji) { group in
                            HStack(spacing: 2) {
                                Text(group.emoji)
                                    .font(.appSystem(size: 12))
                                Text("\(group.count)")
                                    .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if groupedReactions.count > 4 {
                            Text("+\(groupedReactions.count - 4)")
                                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Zaps — compact
            if !parsedZaps.isEmpty {
                Button {
                    showingZappersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text(compactZapText)
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Reposts — compact
            if !detailedReposts.isEmpty {
                Button {
                    showingRepostersSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostersMapped.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    private var compactZapText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let totalStr = formatter.string(from: NSNumber(value: totalZappedSats)) ?? "\(totalZappedSats)"
        return "\(parsedZaps.count) · \(totalStr)"
    }
}
