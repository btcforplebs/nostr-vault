import SwiftUI

/// One conversation found by the Messages search.
struct DMSearchHit: Identifiable {
    let conversation: DMConversation
    /// From Requests (outside your Web of Trust) rather than the inbox.
    let isRequest: Bool
    /// The matched words when the hit is in the message text; nil when the
    /// name matched, so the row shows the latest message as usual.
    let excerpt: String?
    var id: String { conversation.id }
}

enum DMSearchHits {
    /// Inbox hits first, then Requests, each in the lists' own order. Only
    /// reads conversations already decrypted on this device (DMSearch).
    @MainActor
    static func find(_ query: String, inbox: [DMConversation], requests: [DMConversation],
                     profiles: [String: FeedProfile]) -> [DMSearchHit] {
        guard !DMSearch.normalizedQuery(query).isEmpty else { return [] }
        func hits(_ list: [DMConversation], isRequest: Bool) -> [DMSearchHit] {
            list.compactMap { conversation in
                let p = profiles[conversation.id]
                if DMSearch.nameMatches(query, names: [p?.displayName, p?.name, p?.nip05]) {
                    return DMSearchHit(conversation: conversation, isRequest: isRequest, excerpt: nil)
                }
                let texts = conversation.messages.map(\.content)
                guard let i = DMSearch.newestTextMatch(query, texts: texts) else { return nil }
                return DMSearchHit(conversation: conversation, isRequest: isRequest,
                                   excerpt: DMSearch.excerpt(texts[i], query: query))
            }
        }
        return hits(inbox, isRequest: false) + hits(requests, isRequest: true)
    }
}

/// What Messages shows while a search is typed: the matching conversations,
/// pushed into on iPhone/Mac, or selected into the right pane on iPad.
struct DMSearchResultsList: View {
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService
    let hits: [DMSearchHit]
    let query: String
    /// The iPad two-pane inbox's selection; nil pushes the thread instead.
    var selection: Binding<String?>? = nil

    var body: some View {
        Group {
            if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if let selection {
                List(selection: selection) {
                    ForEach(hits) { hit in
                        row(hit).tag(hit.id)
                    }
                }
            } else {
                List {
                    ForEach(hits) { hit in
                        NavigationLink(destination: DMThreadView(counterpartyPubkey: hit.id)
                            .environmentObject(nostrService)
                            .environmentObject(configService)) {
                            row(hit)
                        }
                        .listRowBackground(Color.platformSecondaryGroupedBackground)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.platformWindowBackground.ignoresSafeArea())
    }

    private func row(_ hit: DMSearchHit) -> some View {
        // A Requests hit says so, ahead of the matched words or the latest message.
        let text = hit.excerpt ?? (hit.isRequest ? String((hit.conversation.lastMessage?.content ?? "").prefix(60)) : nil)
        let preview = hit.isRequest ? "Request · " + (text ?? "") : text
        return ConversationRow(conversation: hit.conversation, nostrService: nostrService, preview: preview)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)
    }
}
