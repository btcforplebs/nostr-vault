import SwiftUI

extension NoteRow {
    // MARK: - Inline Engagement Bar

    @ViewBuilder
    func engagementBar(reactors: [(pubkey: String, emoji: String)], zaps: [(pubkey: String, amount: Int64)], reposters: [String], quoters: [String]) -> some View {
        let uniqueReactors: [(pubkey: String, emoji: String)] = {
            var seen = Set<String>()
            return reactors.filter { seen.insert($0.pubkey).inserted }
        }()
        let uniqueZapperPubkeys: [String] = {
            var seen = Set<String>()
            return zaps.compactMap { z in
                if seen.contains(z.pubkey) { return nil }
                seen.insert(z.pubkey)
                return z.pubkey
            }
        }()
        let uniqueReposters: [String] = {
            var seen = Set<String>()
            return reposters.filter { seen.insert($0).inserted }
        }()
        let uniqueQuoters: [String] = {
            var seen = Set<String>()
            return quoters.filter { seen.insert($0).inserted }
        }()
        let totalSats = zaps.reduce(Int64(0)) { $0 + $1.amount }

        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.top, 6)

        HStack(spacing: 14) {
            // Reactions — hidden entirely in Zaps Only mode
            if !uniqueReactors.isEmpty && !configService.config.zapsOnlyMode {
                Button {
                    showingReactors = true
                } label: {
                    HStack(spacing: 4) {
                        Text(reactionEmojiSummary(uniqueReactors.map(\.emoji), limit: 2))
                            .font(.appSystem(size: 10))

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReactors.prefix(3).enumerated()), id: \.offset) { _, reactor in
                                AvatarView(url: nostrService.profiles[reactor.pubkey]?.pictureURL, pubkey: reactor.pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReactors.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.pink.opacity(0.8))

                        if let date = latestReactionDate {
                            Text(timeAgo(from: date))
                                .font(.appSystem(size: 10, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(uniqueReactors.count) reaction\(uniqueReactors.count == 1 ? "" : "s")")
            }

            // Reposts
            if !uniqueReposters.isEmpty {
                Button {
                    showingReposters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.green)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueReposters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueReposters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green.opacity(0.8))
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(uniqueReposters.count) repost\(uniqueReposters.count == 1 ? "" : "s")")
            }

            // Quotes
            if !uniqueQuoters.isEmpty {
                Button {
                    showingQuoters = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "quote.bubble.fill")
                            .font(.appSystem(size: 10, weight: .bold))
                            .foregroundColor(.blue)

                        HStack(spacing: -4) {
                            ForEach(Array(uniqueQuoters.prefix(3).enumerated()), id: \.element) { _, pubkey in
                                AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                    .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                            }
                        }

                        Text("\(uniqueQuoters.count)")
                            .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.blue.opacity(0.8))
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(uniqueQuoters.count) quote\(uniqueQuoters.count == 1 ? "" : "s")")
            }

            // Zaps
            if !uniqueZapperPubkeys.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.appSystem(size: 10, weight: .bold))
                        .foregroundColor(.orange)

                    HStack(spacing: -4) {
                        ForEach(Array(uniqueZapperPubkeys.prefix(3).enumerated()), id: \.element) { _, pubkey in
                            AvatarView(url: nostrService.profiles[pubkey]?.pictureURL, pubkey: pubkey, size: 16)
                                .overlay(Circle().stroke(Color.platformSecondaryGroupedBackground, lineWidth: 1))
                        }
                    }

                    Text(Self.formatSats(totalSats))
                        .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Zapped \(Self.formatSats(totalSats)) by \(uniqueZapperPubkeys.count) \(uniqueZapperPubkeys.count == 1 ? "person" : "people")")
            }

            Spacer()
        }
        .padding(.top, 6)
        .sheet(isPresented: $showingReactors) {
            ReactorsListView(reactors: uniqueReactors, onDismiss: { showingReactors = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingReposters) {
            RepostersListView(pubkeys: uniqueReposters, onDismiss: { showingReposters = false })
                .environmentObject(nostrService)
        }
        .sheet(isPresented: $showingQuoters) {
            QuotersListView(pubkeys: uniqueQuoters, onDismiss: { showingQuoters = false })
                .environmentObject(nostrService)
        }
        .onAppear {
            let allPubkeys = uniqueReactors.map(\.pubkey) + uniqueZapperPubkeys + uniqueReposters + uniqueQuoters
            let missing = allPubkeys.filter { nostrService.profiles[$0] == nil }
            if !missing.isEmpty {
                nostrService.fetchMissingProfiles(for: Array(Set(missing)))
            }
        }
    }

    private static func formatSats(_ sats: Int64) -> String {
        if sats >= 1_000_000 {
            let m = Double(sats) / 1_000_000.0
            return String(format: "%.1fM sats", m)
        } else if sats >= 10_000 {
            let k = Double(sats) / 1_000.0
            return String(format: "%.1fK sats", k)
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return (formatter.string(from: NSNumber(value: sats)) ?? "\(sats)") + " sats"
        }
    }
}
