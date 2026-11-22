import SwiftUI

/// The first card on a new account's feed when an invite brought it in
/// (setup screens r3, step 5; InviterWelcome): the inviter, "invited you",
/// Wave back (a one-tap public note that mentions them, so they see you
/// made it) and Message. The Vault chip says the key steps are done: setup
/// asks for the key, backup and lock before the feed. Shown for a day, until
/// waved at or closed.
struct InviterWelcomeCard: View {
    let inviter: String
    let onDone: () -> Void

    @ObservedObject private var nostr = NostrService.shared
    @State private var waving = false
    @State private var waveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(url: nostr.profiles[inviter]?.pictureURL, pubkey: inviter, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.appSystem(size: 16, weight: .bold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("invited you to Nostr Vault")
                        .font(.appSystem(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                vaultChip
                Button {
                    InviterWelcome().close()
                    onDone()
                } label: {
                    Image(systemName: "xmark")
                        .font(.appSystem(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            Text(waveFailed ? "Couldn't send your wave. Try again." : "Say hi so \(name) knows you made it.")
                .font(.appSystem(size: 15))
                .foregroundColor(waveFailed ? .red : .primary)

            HStack(spacing: 10) {
                Button(action: wave) {
                    HStack(spacing: 6) {
                        if waving { ProgressView().controlSize(.small).tint(.onAccent) } else { Text("👋") }
                        Text("Wave back").font(.appSystem(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color.havenPurple))
                }
                .buttonStyle(.plain)
                .disabled(waving || !ConfigService.shared.activeAccountCanSign)

                Button {
                    NotificationCenter.default.post(name: .havenOpenDMInbox, object: inviter)
                } label: {
                    Text("Message")
                        .font(.appSystem(size: 15, weight: .semibold))
                        .foregroundColor(.accentText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(Capsule().stroke(Color.cardLine(0.5), lineWidth: 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cardLine(0.3), lineWidth: 1))
        .task { await loadProfileIfNeeded() }
    }

    /// Key, backup and lock: all three are done before setup lets you in.
    private var vaultChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill").font(.appSystem(size: 11, weight: .bold))
            Text("Vault 3/3").font(.appSystem(size: 12, weight: .semibold))
        }
        .foregroundColor(.havenOnline)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
        .background(Capsule().fill(Color.havenOnline.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vault: key, backup and lock done")
    }

    private var name: String {
        nostr.profiles[inviter]?.bestName ?? ProfileFormat.shortPubkey(inviter)
    }

    private func loadProfileIfNeeded() async {
        guard nostr.profiles[inviter] == nil else { return }
        let events = await nostr.fetchEvents(filter: ["kinds": [0], "authors": [inviter]], from: ReferralLookup.relays)
        nostr.ingestProfiles(events.filter { $0.pubkey == inviter })
    }

    private func wave() {
        guard let npub = ProfileFormat.npub(inviter) else { return }
        let account = ConfigService.shared.activeAccountHexPubkey.lowercased()
        waving = true
        waveFailed = false
        Task { @MainActor in
            let event = await nostr.signEventAsync(kind: 1, content: InviterWelcome.waveContent(inviterNpub: npub),
                                                   tags: InviterWelcome.waveTags(inviter: inviter))
            waving = false
            // Only as the account this card is for.
            guard let event, event.pubkey.lowercased() == account else {
                waveFailed = true
                return
            }
            nostr.postEvent(event)
            InviterWelcome().markWaved()
            withAnimation(.easeOut(duration: 0.25)) { onDone() }
        }
    }
}

/// Where the feed puts InviterWelcomeCard: shows it for the active account
/// while InviterWelcome says so, and follows account switches.
struct InviterWelcomeSlot: View {
    @ObservedObject private var config = ConfigService.shared
    @State private var inviter: String?

    var body: some View {
        // A VStack, not a Group: an empty Group has nothing to hang
        // onAppear on, so it would never look.
        VStack(spacing: 0) {
            if let inviter {
                InviterWelcomeCard(inviter: inviter) { self.inviter = nil }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: config.activeAccountHexPubkey) { _, _ in refresh() }
    }

    private func refresh() {
        inviter = InviterWelcome().inviter(for: config.activeAccountHexPubkey)
    }
}
