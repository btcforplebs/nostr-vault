import SwiftUI

/// Search tab's "For you": people your follows follow, your topics and notes
/// that match them. Everything here was ranked on device from the relay's
/// own trust graph and feed (`SearchRecommendations`).
struct SearchRecommendationsSection: View {
    let people: [SearchRecommendations.Person]
    let topics: [String]
    let notes: [FeedNote]
    let onProfile: (String) -> Void
    let onTopic: (String) -> Void
    let onNote: (FeedNote) -> Void
    let onMedia: (URL, [URL]) -> Void

    @EnvironmentObject private var nostrService: NostrService
    @ObservedObject private var feedService = FeedService.shared

    /// People with a loaded profile; the rest show once theirs arrives.
    private var namedPeople: [(SearchRecommendations.Person, FeedProfile)] {
        people.compactMap { person in
            guard let profile = nostrService.profiles[person.pubkey],
                  profile.name != nil || profile.displayName != nil else { return nil }
            return (person, profile)
        }
    }

    var body: some View {
        let named = namedPeople
        if !named.isEmpty || !topics.isEmpty || !notes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.appSystem(size: 12, weight: .semibold))
                        .foregroundColor(Color.havenPurple)
                    Text("For you")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Label("Ranked by your relay", systemImage: "externaldrive.connected.to.line.below")
                        .font(.appSystem(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .help("Picked on this device from your relay's trust graph and feed. No recommendation server is asked.")
                }

                if !named.isEmpty { peopleRail(named) }
                if !topics.isEmpty { topicRail }
                if !notes.isEmpty { pickedNotes }
            }
        }
    }

    // MARK: People

    private func peopleRail(_ named: [(SearchRecommendations.Person, FeedProfile)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People you may know")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(named, id: \.0.pubkey) { person, profile in
                        personCard(person, profile)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func personCard(_ person: SearchRecommendations.Person, _ profile: FeedProfile) -> some View {
        Button(action: { onProfile(person.pubkey) }) {
            VStack(spacing: 6) {
                AvatarView(url: profile.pictureURL, pubkey: person.pubkey, size: 48)
                Text(profile.bestName)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(person.vouches) of your follows")
                    .font(.appSystem(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 96)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.bestName), followed by \(person.vouches) people you follow")
    }

    // MARK: Topics

    private var topicRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your topics")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(topics, id: \.self) { tag in
                        Button(action: { onTopic(tag) }) {
                            Text("#\(tag)")
                                .font(.appSystem(size: 12, weight: .medium))
                                .foregroundColor(Color.havenPurple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.havenPurple.opacity(0.12))
                                .cornerRadius(14)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Notes

    private var pickedNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Picked from your topics")
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            VStack(spacing: 8) {
                ForEach(notes) { note in
                    FeedNoteRow(
                        note: note,
                        profile: nostrService.profiles[note.pubkey],
                        rowData: FeedNoteRowData.resolve(
                            for: note,
                            feedService: feedService,
                            nostrService: nostrService
                        ),
                        onProfile: onProfile,
                        onMedia: onMedia,
                        showParent: false
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onNote(note) }
                }
            }
            .environment(\.feedActions, .make(feedService: feedService, nostrService: nostrService))
        }
    }
}
