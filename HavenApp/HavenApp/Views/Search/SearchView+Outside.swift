import SwiftUI

// MARK: - Outside your web

extension SearchView {
    /// People and notes from outside your web, folded under one line until
    /// asked for (GlobalSearchRanking.splitOutside; Logen 2026-11-13 "go all",
    /// option B). Follows the Users / Notes tab picked. Web twin:
    /// components/OutsideFold.jsx in Search.
    @ViewBuilder
    var outsideSection: some View {
        let people = resultTypeFilter == .all || resultTypeFilter == .users ? searchResults.outsideUsers : []
        let notes = resultTypeFilter == .all || resultTypeFilter == .notes ? searchResults.outsideNotes : []
        let count = people.count + notes.count
        if count > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(Motion.toggle) { showsOutside.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                        Text("\(showsOutside ? "Hide" : "Show") \(VaultActivity.outsideLabel(count))")
                        Spacer(minLength: 0)
                        Image(systemName: showsOutside ? "chevron.up" : "chevron.down")
                            .font(.appSystem(size: 11, weight: .semibold))
                    }
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                if showsOutside {
                    LazyVStack(spacing: 8) {
                        ForEach(people, id: \.pubkey) { profile in
                            userRow(pubkey: profile.pubkey, profile: profile)
                        }
                        ForEach(notes) { note in
                            resultNoteRow(note)
                        }
                    }
                    .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}
