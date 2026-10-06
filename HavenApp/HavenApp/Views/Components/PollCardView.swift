import SwiftUI

/// A NIP-88 poll inside a note row: the question, its options and the count.
/// Tapping an option votes (single choice) or picks it (multiple choice, sent
/// with Vote). Results show once you have voted or the poll has closed.
/// Focused, as the note detail's own row, each option also shows who picked it.
struct PollCardView: View {
    let poll: NIP88Poll.Poll
    var isFocused: Bool = false

    @StateObject private var model: PollModel
    @State private var picked: Set<String> = []

    init(poll: NIP88Poll.Poll, isFocused: Bool = false) {
        self.poll = poll
        self.isFocused = isFocused
        _model = StateObject(wrappedValue: PollStore.shared.model(for: poll))
    }

    private var me: String { NostrService.shared.activeHexPubkey }
    private var myPicks: [String] { model.tally.picksByVoter[me] ?? [] }
    private var isClosed: Bool { poll.isClosed() }
    private var showsResults: Bool { isClosed || !myPicks.isEmpty }
    private var canVote: Bool { !isClosed && !me.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !poll.question.isEmpty {
                Text(poll.question)
                    .font(.appSystem(size: isFocused ? 19 : 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            VStack(spacing: 8) {
                ForEach(poll.options) { option in
                    optionRow(option)
                }
            }

            if poll.type == .multiple, canVote, !picked.isEmpty, Set(myPicks) != picked {
                Button {
                    model.vote(poll.options.map(\.id).filter { picked.contains($0) })
                } label: {
                    Text(myPicks.isEmpty ? "Vote" : "Change vote")
                        .font(.appSystem(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Color.havenPurple)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isSending)
            }

            footer

            if let error = model.sendError {
                Text(error)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .task { await model.load() }
        .onChange(of: myPicks) { _, picks in picked = Set(picks) }
        .onAppear { if picked.isEmpty { picked = Set(myPicks) } }
    }

    // MARK: Option

    private func optionRow(_ option: NIP88Poll.Option) -> some View {
        let mine = myPicks.contains(option.id)
        let selected = poll.type == .multiple ? picked.contains(option.id) : mine
        let share = model.tally.share(option.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                tap(option)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectionIcon(selected))
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(selected ? .havenPurple : .secondary)
                    Text(option.label)
                        .font(.appSystem(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if showsResults {
                        Text("\(Int((share * 100).rounded()))%")
                            .font(.appSystem(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundColor(selected ? .havenPurple : .secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.secondary.opacity(0.1)
                            if showsResults {
                                Color.havenPurple.opacity(selected ? 0.28 : 0.14)
                                    .frame(width: geo.size.width * share)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Color.havenPurple.opacity(0.7) : .clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .animation(.easeOut(duration: 0.25), value: share)
            }
            .buttonStyle(.plain)
            .disabled(!canVote || model.isSending)
            .accessibilityLabel(option.label)
            .accessibilityValue(showsResults ? "\(model.tally.count(option.id)) votes" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if isFocused, showsResults {
                PollOptionVoters(pubkeys: Array(model.tally.votersByOption[option.id] ?? []))
            }
        }
    }

    private func selectionIcon(_ selected: Bool) -> String {
        switch poll.type {
        case .single: return selected ? "largecircle.fill.circle" : "circle"
        case .multiple: return selected ? "checkmark.square.fill" : "square"
        }
    }

    private func tap(_ option: NIP88Poll.Option) {
        guard canVote else { return }
        switch poll.type {
        case .single:
            guard myPicks != [option.id] else { return }
            model.vote([option.id])
        case .multiple:
            if picked.contains(option.id) { picked.remove(option.id) } else { picked.insert(option.id) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis")
                .font(.appSystem(size: 10, weight: .semibold))
            Text(model.tally.voters.count == 1 ? "1 vote" : "\(model.tally.voters.count) votes")
            if poll.type == .multiple { Text("· Pick any") }
            if let endsAt = poll.endsAt {
                if isClosed {
                    Text("· Final results")
                } else {
                    Text("· Ends ") + Text(endsAt, format: .relative(presentation: .named))
                }
            }
            if model.isSending || model.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .font(.appSystem(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .lineLimit(1)
    }
}

/// The people behind one option, in the note detail. Kept apart from the card
/// so only the detail's row watches profiles.
private struct PollOptionVoters: View {
    let pubkeys: [String]
    @ObservedObject private var nostrService = NostrService.shared
    private static let shownAvatars = 12

    var body: some View {
        if !pubkeys.isEmpty {
            HStack(spacing: -6) {
                ForEach(pubkeys.sorted().prefix(Self.shownAvatars), id: \.self) { pubkey in
                    AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 22)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .accessibilityLabel(nostrService.profiles[pubkey]?.bestName ?? "")
                }
                if pubkeys.count > Self.shownAvatars {
                    Text("+\(pubkeys.count - Self.shownAvatars)")
                        .font(.appSystem(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 10)
                }
            }
            .padding(.leading, 12)
        }
    }
}

extension FeedNote {
    /// The poll this note is, when it is a NIP-88 poll with options.
    var poll: NIP88Poll.Poll? {
        NIP88Poll.Poll(id: id, pubkey: pubkey, kind: kind, content: content, tags: tags)
    }

    /// What a one-line row shows for a poll: its question, marked as a poll.
    var pollSummary: String? {
        poll.map { "Poll: " + ($0.question.isEmpty ? $0.options.map(\.label).joined(separator: " / ") : $0.question) }
    }

    /// A condensed row's text in place of the raw body: an article's title or
    /// a poll's question. Nil when the body is the text.
    var condensedTitle: String? {
        kind == 30023 ? longFormDisplayTitle : pollSummary
    }
}
