import SwiftUI

// MARK: - Step 15: Who told you about Nostr Vault?

/// Setup's referrer step, on the create-account and bring-your-own-key
/// paths, skippable: scan their QR code or paste their link or npub, see
/// their profile card, follow them, then pick from up to 10 of the people
/// they follow (most-followed first, all ticked). Nothing is published here:
/// the wizard follows them once setup has stored the key
/// (`SetupReferral.pendingFollows`). A profile link opened before setup
/// (`SetupReferral.pendingReferrer`) starts the step on that person.
/// Android's twin is ReferrerStep.kt.
struct ReferrerStep: View {
    /// Your own key (hex), never offered; nil when not known yet.
    let ownPubkey: String?
    /// Also leave out the people this key already follows (an existing key).
    let excludeOwnFollows: Bool
    /// Who to follow; empty when skipped.
    let onFinish: ([String]) -> Void

    private enum Phase: Equatable {
        case input
        case loading
        case found(String)
        case suggest(String)
    }

    @ObservedObject private var nostr = NostrService.shared
    @State private var phase: Phase = .input
    @State private var input = ""
    @State private var errorText: String?
    @State private var person: ReferralLookup.Person?
    @State private var suggestions: [String] = []
    @State private var picked: Set<String> = []
    @State private var loadingSuggestions = false
    @State private var showingScanner = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 12)
            header
            switch phase {
            case .input: inputSection
            case .loading:
                ProgressView().controlSize(.large).padding(.vertical, 40)
                    .accessibilityLabel("Looking them up")
            case .found(let pubkey): foundSection(pubkey)
            case .suggest(let pubkey): suggestSection(pubkey)
            }
            Spacer(minLength: 8)
        }
        .opacity(appeared ? 1 : 0)
        .animation(WizardAnimations.fadeIn, value: appeared)
        .animation(WizardAnimations.springGentle, value: phase)
        .onAppear {
            appeared = true
            // Opened from someone's profile link before setup: start on them.
            if phase == .input, input.isEmpty, let hex = SetupReferral().pendingReferrer,
               let npub = ProfileFormat.npub(hex) {
                input = npub
                lookUp()
            }
        }
        // A profile link opened while this step is up.
        .onReceive(NotificationCenter.default.publisher(for: .havenSetupReferrer)) { note in
            guard let hex = note.object as? String, let npub = ProfileFormat.npub(hex),
                  phase == .input || phase == .found(person?.pubkey ?? "") else { return }
            input = npub
            lookUp()
        }
        #if os(iOS)
        .sheet(isPresented: $showingScanner) {
            QRScannerView(title: "Scan their profile code",
                          validate: { Self.pubkey(from: $0) == nil ? "That isn't a profile code" : nil }) { code in
                showingScanner = false
                input = code
                lookUp()
            }
        }
        #endif
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 8) {
            Text("Who told you about Nostr Vault?")
                .font(.appSystem(size: 24, weight: .bold))
                .foregroundColor(WizardColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.appSystem(size: 15))
                .foregroundColor(WizardColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch phase {
        case .suggest(let pubkey): return "These are people \(name(pubkey)) follows. Untick anyone you'd rather not follow."
        default:
            #if os(iOS)
            return "Scan their profile code, or paste their link or npub, and follow them. People they follow are a good start."
            #else
            return "Paste their profile link or npub and follow them. People they follow are a good start."
            #endif
        }
    }

    private var inputSection: some View {
        VStack(spacing: 16) {
            WizardInputField(label: "Their profile link or npub", text: $input,
                             placeholder: "nostrvault.app/p/… or npub1…",
                             onScan: { showingScanner = true })
                .onChange(of: input) { _, _ in errorText = nil }
                .onSubmit { lookUp() }

            HStack {
                Button(action: paste) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.appSystem(size: 14, weight: .medium))
                        .foregroundColor(WizardColors.accentPrimary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if let errorText {
                Text(errorText)
                    .font(.appSystem(size: 13))
                    .foregroundColor(WizardColors.error)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: String(localized: "setup.action.continue"), action: lookUp,
                                    disabled: input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                WizardSkipLink(title: "Skip, nobody told me") { finish([]) }
            }
            .padding(.top, 8)
        }
    }

    private func foundSection(_ pubkey: String) -> some View {
        VStack(spacing: 18) {
            WizardGlassCard(isSelected: true) {
                VStack(spacing: 10) {
                    AvatarView(url: nostr.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 72)
                    Text(name(pubkey))
                        .font(.appSystem(size: 20, weight: .bold))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(1)
                    if let nip05 = nostr.profiles[pubkey]?.nip05, !nip05.isEmpty {
                        Text(nip05.hasPrefix("_@") ? String(nip05.dropFirst(2)) : nip05)
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                            .lineLimit(1)
                    }
                    if let about = nostr.profiles[pubkey]?.about, !about.isEmpty {
                        Text(about)
                            .font(.appSystem(size: 14))
                            .foregroundColor(WizardColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    } else if person?.hasProfile == false {
                        Text("No profile found yet. You can still follow this key.")
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textMuted)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: "Follow \(name(pubkey))") { showSuggestions(pubkey) }
                WizardSkipLink(title: "Not them? Try another") {
                    phase = .input
                    person = nil
                }
                WizardSkipLink(title: "Skip") { finish([]) }
            }
        }
    }

    private func suggestSection(_ pubkey: String) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                AvatarView(url: nostr.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 32)
                Text("You'll follow \(name(pubkey))")
                    .font(.appSystem(size: 15, weight: .semibold))
                    .foregroundColor(WizardColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(WizardColors.success)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(WizardColors.bgCard)
            .cornerRadius(12)
            .accessibilityElement(children: .combine)

            if loadingSuggestions {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding who they follow…")
                        .font(.appSystem(size: 14))
                        .foregroundColor(WizardColors.textSecondary)
                }
                .padding(.vertical, 24)
            } else if suggestions.isEmpty {
                Text("We couldn't find anyone they follow yet.")
                    .font(.appSystem(size: 14))
                    .foregroundColor(WizardColors.textSecondary)
                    .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(suggestions, id: \.self) { key in
                        suggestionRow(key)
                        if key != suggestions.last {
                            Divider().overlay(WizardColors.borderSubtle).padding(.leading, 60)
                        }
                    }
                }
                .background(WizardColors.bgCard)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(WizardColors.borderSubtle, lineWidth: 1))
            }

            VStack(spacing: 12) {
                WizardPrimaryButton(title: followTitle, action: { finish([pubkey] + suggestions.filter(picked.contains)) },
                                    disabled: loadingSuggestions)
                if !suggestions.isEmpty && !loadingSuggestions {
                    WizardSkipLink(title: "Only follow \(name(pubkey))") { finish([pubkey]) }
                }
            }
            .padding(.top, 4)
        }
    }

    private func suggestionRow(_ key: String) -> some View {
        let on = picked.contains(key)
        return Button {
            if on { picked.remove(key) } else { picked.insert(key) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: nostr.profiles[key]?.pictureURL, pubkey: key, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name(key))
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(WizardColors.textPrimary)
                        .lineLimit(1)
                    if let about = nostr.profiles[key]?.about, !about.isEmpty {
                        Text(about)
                            .font(.appSystem(size: 13))
                            .foregroundColor(WizardColors.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.appSystem(size: 22))
                    .foregroundColor(on ? WizardColors.accentPrimary : WizardColors.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(on ? "Ticked: you'll follow them" : "Not ticked")
    }

    private var followTitle: String {
        let count = 1 + suggestions.filter(picked.contains).count
        return count == 1 ? "Follow 1 person" : "Follow \(count) people"
    }

    // MARK: Actions

    /// Their pubkey (hex) from a profile link (nostrvault.app/p/…,
    /// nostrvault://p/…, nostr:npub…), or a bare npub or nprofile.
    static func pubkey(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .profile(let id) = NostrURI(string: trimmed) {
            return QuoteReference.profilePubkey(fromBech32: id)
        }
        return QuoteReference.profilePubkey(fromBech32: trimmed)
    }

    private func name(_ pubkey: String) -> String {
        nostr.profiles[pubkey]?.bestName ?? ProfileFormat.shortPubkey(pubkey)
    }

    private func paste() {
        #if os(iOS)
        if let text = UIPasteboard.general.string { input = text }
        #else
        if let text = NSPasteboard.general.string(forType: .string) { input = text }
        #endif
        if Self.pubkey(from: input) != nil { lookUp() }
    }

    private func lookUp() {
        guard let pubkey = Self.pubkey(from: input) else {
            errorText = "That isn't a profile link or npub. It starts with nostrvault.app/p/ or npub1."
            return
        }
        guard pubkey != ownPubkey else {
            errorText = "That's you. Paste the link of the person who told you."
            return
        }
        errorText = nil
        phase = .loading
        Task {
            let found = await ReferralLookup.person(pubkey)
            guard phase == .loading else { return }
            person = found
            phase = .found(pubkey)
        }
    }

    private func showSuggestions(_ pubkey: String) {
        phase = .suggest(pubkey)
        guard let person, person.pubkey == pubkey else { return }
        loadingSuggestions = true
        Task {
            var exclude = Set<String>()
            if let ownPubkey {
                exclude.insert(ownPubkey)
                if excludeOwnFollows { exclude.formUnion(await ReferralLookup.person(ownPubkey).follows) }
            }
            let picks = await ReferralLookup.suggestions(for: person, exclude: exclude)
            guard phase == .suggest(pubkey) else { return }
            suggestions = picks
            picked = Set(picks)
            loadingSuggestions = false
        }
    }

    private func finish(_ follows: [String]) {
        onFinish(follows)
    }
}
