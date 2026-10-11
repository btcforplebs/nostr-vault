import SwiftUI

extension FeedView {
    // MARK: - Loading Contacts

    var loadingContactsView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.synchronizing"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.fetchingFollows"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    var loadingExtendedNetworkView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.analyzingNetwork"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.findingConnections"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.patience"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Empty State

    var importingFeedView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.havenPurple)
            Text("Your feed fills in as your notes come home")
                .font(.appSystem(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
            Text(ImportTourStage(statusMessage: relayManager.importStatusMessage, completed: false).text)
                .font(.appSystem(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    var emptyStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                // Relay is running but no follows
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.following.title"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(String(localized: "feed.empty.following.subtitle"))
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    var emptyDiscoveryStateView: some View {
        VStack(spacing: 40) {
            if relayManager.isBooting {
                // Relay is still starting up
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.havenPurple)

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.relayStarting"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        Text(relayManager.bootStatusMessage.isEmpty ? String(localized: "feed.empty.initializingRelay") : relayManager.bootStatusMessage)
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.appSystem(size: 56, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 12) {
                        Text(String(localized: "feed.empty.discovery.title"))
                            .font(.appSystem(size: 22, weight: .bold, design: .default))
                            .tracking(0.2)

                        // Nobody followed is the user's to fix; a relay that
                        // returned no follow lists is not, and telling someone
                        // with 400 follows to follow more people reads as the
                        // feature being broken by them.
                        Text(String(localized: feedService.followedPubkeys.isEmpty
                            ? "feed.empty.discovery.subtitle"
                            : "feed.empty.discovery.subtitle.norelaydata"))
                            .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(0.3)
                            .multilineTextAlignment(.center)
                    }
                }

                Button {
                    feedService.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                        Text(String(localized: "feed.action.refresh"))
                    }
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(max(16, min(48, 24))) // Adaptive padding
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Popular Feed States

    var loadingPopularView: some View {
        VStack(spacing: 32) {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.havenPurple)

                VStack(spacing: 8) {
                    Text(String(localized: "feed.loading.findingPopular"))
                        .font(.appSystem(size: 18, weight: .bold, design: .default))
                        .tracking(0.3)
                    Text(String(localized: "feed.loading.scoringEngagement"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(String(localized: "feed.loading.analyzingReactions"))
                .font(.appSystem(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    var emptyPopularStateView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.appSystem(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    Text(String(localized: "feed.empty.popular.title"))
                        .font(.appSystem(size: 22, weight: .bold, design: .default))
                        .tracking(0.2)

                    Text(String(localized: "feed.empty.popular.subtitle"))
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                        .multilineTextAlignment(.center)
                }
            }

            Button {
                feedService.refresh()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise")
                    Text(String(localized: "feed.action.refresh"))
                }
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(max(16, min(48, 24)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    // MARK: - Engagement Stats Badge

    @ViewBuilder
    func engagementBadge(score: Double) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.appSystem(size: 9))
                .foregroundColor(.orange)
            Text(formatEngagementScore(score))
                .font(.appSystem(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.havenPurple.opacity(0.3), lineWidth: 0.5)
        )
    }

    private func formatEngagementScore(_ score: Double) -> String {
        if score >= 1000 {
            return String(format: "%.1fk", score / 1000)
        }
        return String(format: "%.0f", score)
    }
}
