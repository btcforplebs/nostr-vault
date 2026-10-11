import SwiftUI

extension TrustWebView {
    // MARK: - Search

    @ViewBuilder var topRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isWOTTab { searchField.padding(.horizontal) }
            // On the WOT tab a lone "You" chip says nothing the globe doesn't.
            if !isWOTTab || crumbs.count > 1 { crumbRow }
        }
    }

    var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("Find someone", text: $query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .submitLabel(.search)
                .onSubmit { if let first = searchMatches.first { pick(first) } }
            if !query.isEmpty {
                Button { clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .font(.appSystem(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    /// Who the search finds: a pasted key, or names you've seen, people you
    /// follow first.
    private var searchMatches: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count == 64, text.allSatisfy(\.isHexDigit) { return [text.lowercased()] }
        let bare = text.hasPrefix("nostr:") ? String(text.dropFirst(6)) : text
        if bare.lowercased().hasPrefix("npub1"), let hex = NpubValidation.hexPubkey(fromNpub: bare) { return [hex] }
        let people = nostrService.profiles.values.map {
            TrustMap.Person(pubkey: $0.pubkey, names: [$0.displayName, $0.name, $0.nip05].compactMap { $0 })
        }
        return TrustMap.searchPeople(text, in: people, follows: myFollows, web: web)
    }

    func searchResults(maxHeight: CGFloat) -> some View {
        let matches = searchMatches
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches, id: \.self) { pubkey in
                    Button { pick(pubkey) } label: { searchRow(pubkey) }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows how they reach you"))
                }
                if searchingRelays {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching relays…").foregroundColor(.secondary)
                    }
                    .font(.appSystem(size: 14))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                } else if matches.isEmpty {
                    Text("No one called \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D} yet.")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private func searchRow(_ pubkey: String) -> some View {
        let tag = pubkey == me ? "You" : myFollows.contains(pubkey) ? "You follow"
            : web.contains(pubkey) ? "In your web" : nil
        return HStack(spacing: 12) {
            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(name(pubkey)).font(.appSystem(size: 15, weight: .semibold)).foregroundColor(.primary).lineLimit(1)
                if let nip05 = nostrService.profiles[pubkey]?.nip05, !nip05.isEmpty {
                    Text(nip05).font(.appSystem(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let tag {
                Text(tag)
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(tag == "In your web" ? .secondary : .havenPurple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Names you haven't seen yet: ask the search relays, after a pause in
    /// typing. Profiles they return join the cache, so the list re-ranks.
    func searchRelays(_ text: String) {
        relaySearch?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, !trimmed.lowercased().hasPrefix("npub1") else {
            searchingRelays = false
            return
        }
        searchingRelays = true
        relaySearch = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            nostrService.globalSearch(query: trimmed) { results in
                if results.isFinished, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                    searchingRelays = false
                }
            }
            // A relay that never answers mustn't leave the spinner on.
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            searchingRelays = false
        }
    }

    private func pick(_ pubkey: String) {
        clearSearch()
        if isWOTTab { withAnimation(Motion.fade) { searchOpen = false } }
        pubkey == me ? closeCard() : openCard(pubkey)
    }

    func clearSearch() {
        query = ""
        searchFocused = false
        relaySearch?.cancel()
        searchingRelays = false
    }
}
