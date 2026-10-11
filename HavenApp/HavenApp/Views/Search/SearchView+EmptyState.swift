import SwiftUI
import Combine

extension SearchView {
    @ViewBuilder
    var emptyState: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Recent searches
                if !recentSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Recent")
                                .font(.appSystem(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Clear") {
                                recentSearches = []
                                UserDefaults.standard.removeObject(forKey: "recentSearches")
                            }
                            .font(.appSystem(size: 12))
                            .foregroundColor(.secondary.opacity(0.7))
                            .buttonStyle(.plain)
                        }

                        FlowLayout(spacing: 6) {
                            ForEach(recentSearches, id: \.self) { query in
                                Button(action: { searchQuery = query }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.appSystem(size: 10))
                                        Text(query)
                                            .font(.appSystem(size: 12, weight: .medium))
                                    }
                                    .foregroundColor(.primary.opacity(0.8))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(14)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Trending hashtags
                let trending = cachedTrending
                if !trending.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trending")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        FlowLayout(spacing: 6) {
                            ForEach(trending, id: \.self) { tag in
                                Button(action: { searchQuery = "#\(tag)" }) {
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

                // Suggested profiles
                let suggested = cachedSuggested
                if !suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Active in your feed")
                            .font(.appSystem(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 4) {
                            ForEach(suggested, id: \.0) { pubkey, profile in
                                Button(action: { showingProfile = pubkey }) {
                                    HStack(spacing: 10) {
                                        AvatarView(url: profile.pictureURL, pubkey: pubkey, size: 34)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(profile.bestName)
                                                .font(.appSystem(size: 13, weight: .medium))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if let nip05 = profile.nip05, !nip05.isEmpty {
                                                Text(nip05)
                                                    .font(.appSystem(size: 11))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.appSystem(size: 11, weight: .semibold))
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Fallback if nothing to show
                if recentSearches.isEmpty && trending.isEmpty && suggested.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.appSystem(size: 48, weight: .thin))
                            .foregroundColor(.secondary.opacity(0.5))
                        VStack(spacing: 8) {
                            Text("Search")
                                .font(.appSystem(size: 18, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("Find users, notes, hashtags and links\nOr paste a note1 or nevent1 ID")
                                .font(.appSystem(size: 13))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding()
        }
        .scrollDirectionTracking(feedService: feedService)
    }

    /// Simple wrapping layout for chips
    private struct FlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? .infinity
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > width && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            return CGSize(width: width, height: y + rowHeight)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            var x: CGFloat = bounds.minX
            var y: CGFloat = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > bounds.maxX && x > bounds.minX {
                    x = bounds.minX
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
    }

    /// One chip per Global search source: searching / N found / no answer.
    @ViewBuilder
    var globalSourceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(globalSources) { source in
                    globalSourceChip(source)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func globalSourceChip(_ source: GlobalSearchSourceStatus) -> some View {
        let (text, color): (String, Color) = {
            switch source.state {
            case .searching: return (source.count > 0 ? "\(source.count) so far" : "searching", .secondary)
            case .found(let n): return ("\(n) found", n > 0 ? .havenOnline : .secondary)
            case .noAnswer(let reason): return ("no answer: \(reason)", .orange)
            }
        }()
        let icon: String = {
            switch source.role {
            case .device:
                #if os(macOS)
                return "desktopcomputer"
                #else
                return "iphone"
                #endif
            case .mac: return "desktopcomputer"
            case .relay: return "antenna.radiowaves.left.and.right"
            }
        }()
        HStack(spacing: 5) {
            if case .searching = source.state {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: icon)
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(color)
            }
            Text(source.label)
                .font(.appSystem(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(0.85))
            if let detail = source.detail {
                Text(detail)
                    .font(.appSystem(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(text)
                .font(.appSystem(size: 11))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .help("\(source.label): \(text)")
    }
}
