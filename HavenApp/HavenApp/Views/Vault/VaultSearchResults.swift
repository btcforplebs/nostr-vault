import SwiftUI

/// What the Vault's search found, in place of the Vault's list while the bar
/// is open: a row of section chips, then People, Notes, Articles, Media,
/// Hashtags and Links. "All" shows the first few of each; a chip shows that
/// section whole.
struct VaultSearchResults: View {
    @ObservedObject var model: VaultSearchModel
    let onProfile: (String) -> Void
    /// The Mac opens a note by tap; iOS rows are navigation links.
    let onNote: (String) -> Void

    @State private var section: VaultSearchLogic.Section?
    @Environment(\.openURL) private var openURL

    /// Rows per section under "All".
    private static let preview = 5
    /// Rows in one section. The relay walk keeps every match; this keeps a
    /// common word from building thousands of rows.
    private static let sectionCap = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.status {
            case .idle:
                message(icon: "magnifyingglass",
                        title: "Search your Vault",
                        detail: "Notes, people, hashtags, links, articles and media stored on this device's relay.")
            case .relayDown:
                message(icon: "antenna.radiowaves.left.and.right.slash",
                        title: "Your Vault's relay isn't running",
                        detail: "Search works once it has started.")
            case .searching where model.results.isEmpty:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Searching your Vault…")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            case .done where model.results.isEmpty:
                message(icon: "doc.text.magnifyingglass",
                        title: "Nothing in your Vault matches",
                        detail: "“\(model.resultsQuery)”")
            default:
                chips
                sections
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.resultsQuery) { _, _ in section = nil }
    }

    // MARK: - Chips

    private var visibleSections: [VaultSearchLogic.Section] {
        VaultSearchLogic.Section.allCases.filter { model.results.count($0) > 0 }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", symbol: "square.stack", count: nil, isOn: section == nil) { section = nil }
                ForEach(visibleSections, id: \.self) { s in
                    chip(title: s.title, symbol: s.symbol, count: model.results.count(s), isOn: section == s) {
                        section = s
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .animation(Motion.toggle, value: section)
    }

    private func chip(title: String, symbol: String, count: Int?, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.appSystem(size: 12, weight: .semibold))
                Text(title)
                    .font(.appSystem(size: 13, weight: .semibold))
                if let count {
                    Text(count.formatted())
                        .font(.appSystem(size: 12, weight: .medium))
                        .foregroundColor(isOn ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundColor(isOn ? .white : .primary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(isOn ? Color.havenPurple : Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        let shown = section.map { [$0] } ?? visibleSections
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(shown, id: \.self) { s in
                sectionView(s, limit: section == nil ? Self.preview : Self.sectionCap)
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ s: VaultSearchLogic.Section, limit: Int) -> some View {
        let total = model.results.count(s)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.title)
                    .font(.appSystem(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if total > limit, section == nil {
                    Button("See all \(total.formatted())") { section = s }
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.havenPurple)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)

            switch s {
            case .people:
                ForEach(model.results.people.prefix(limit), id: \.pubkey) { profile in
                    ProfileResultRow(profile: profile)
                        .onTapGesture { onProfile(profile.pubkey) }
                        .accessibilityAddTraits(.isButton)
                }
            case .notes, .articles, .media:
                ForEach(model.results.notes(in: s).prefix(limit)) { note in
                    noteRow(note)
                }
            case .hashtags:
                ForEach(model.results.hashtags.prefix(limit), id: \.self) { tag in
                    hashtagRow(tag)
                }
            case .links:
                ForEach(model.results.links.prefix(limit), id: \.url) { link in
                    linkRow(link)
                }
            }

            if section != nil, total > limit {
                Text("Showing the newest \(limit.formatted()) of \(total.formatted())")
                    .font(.appSystem(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func noteRow(_ note: FeedNote) -> some View {
        let event = NostrEvent(id: note.id, pubkey: note.pubkey,
                               created_at: Int64(note.createdAt.timeIntervalSince1970),
                               kind: note.kind, tags: note.tags, content: note.content, sig: "")
        #if os(iOS)
        NoteNavigationLink(note: note) {
            NoteRow(event: event, truncate: true)
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        #else
        NoteRow(event: event, truncate: true)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture { onNote(note.id) }
        #endif
    }

    private func hashtagRow(_ tag: String) -> some View {
        Button {
            // The hashtag's own feed, as tapping a #tag in a note opens.
            if let url = HashtagLink.url(for: tag) { openURL(url) }
        } label: {
            HStack {
                Text("#\(tag)")
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.havenPurple)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func linkRow(_ link: VaultSearchLogic.Link) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            Text(link.title)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.havenPurple)
                .lineLimit(1)
            Text(link.url)
                .font(.appSystem(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .padding(.horizontal, 16)

        // A URL that does not parse stays an inert row rather than a dead link.
        if let url = URL(string: link.url) {
            Link(destination: url) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 40, weight: .thin))
                .foregroundColor(.havenPurple)
            Text(title)
                .font(.appSystem(size: 17, weight: .bold))
            Text(detail)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
