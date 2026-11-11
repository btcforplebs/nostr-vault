import SwiftUI

extension FeedView {
    // MARK: - Loading Contacts

    var loadingContactsView: some View {
        FeedLoadingRows()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.platformControlBackground)
    }

    var loadingExtendedNetworkView: some View {
        FeedLoadingRows()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        FeedLoadingRows()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.platformControlBackground)
    }

    /// Popular's empty state, worded for Catch Up and Underrated too.
    private var dvmEmptyText: (icon: String, title: String, subtitle: String) {
        switch feedService.feedMode {
        case .catchUp:
            return ("clock.arrow.circlepath", "All caught up",
                    "Nobody you follow posted in the last two weeks, or their posts haven't reached your vault yet.")
        case .underrated:
            let state = UnderratedEmptyState.of(reason: feedService.underratedEmptyReason,
                                                building: ImportJobsService.shared.runningJob == ImportJobs.widerNetwork)
            return ("binoculars", state.title, state.subtitle)
        default:
            return ("chart.line.uptrend.xyaxis", String(localized: "feed.empty.popular.title"),
                    String(localized: "feed.empty.popular.subtitle"))
        }
    }

    var emptyPopularStateView: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Image(systemName: dvmEmptyText.icon)
                    .font(.appSystem(size: 56, weight: .thin))
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.havenPurple, Color.havenPurpleLight]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 12) {
                    Text(dvmEmptyText.title)
                        .font(.appSystem(size: 22, weight: .bold, design: .default))
                        .tracking(0.2)

                    Text(dvmEmptyText.subtitle)
                        .font(.appSystem(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(0.3)
                        .multilineTextAlignment(.center)
                }
            }

            if feedService.feedMode == .underrated {
                // Underrated alone: a follows-only web offers to build the
                // wider network instead of a Refresh that cannot help.
                UnderratedEmptyAction(feedService: feedService)
            } else {
                dvmRefreshButton
            }
        }
        .padding(max(16, min(48, 24)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.platformControlBackground)
    }

    private var dvmRefreshButton: some View {
        Button {
            feedService.refresh()
        } label: {
            DvmEmptyButtonLabel(icon: "arrow.clockwise", title: String(localized: "feed.action.refresh"))
        }
        .buttonStyle(.plain)
    }
}

/// The empty DVM feed's purple button face.
private struct DvmEmptyButtonLabel: View {
    let icon: String?
    let title: String
    var busy = false

    var body: some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small).tint(.black)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(title)
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
        .opacity(busy ? 0.7 : 1)
    }
}

/// Underrated's empty-screen button (UnderratedEmptyState): Refresh Feed, or
/// for a follows-only web Build your wider network, which runs the Vault's
/// `wider_network` job through ImportJobsService, shows it running, and
/// reloads Underrated when it ends.
private struct UnderratedEmptyAction: View {
    @ObservedObject var feedService: FeedService
    @ObservedObject private var jobs = ImportJobsService.shared

    private var building: Bool { jobs.runningJob == ImportJobs.widerNetwork }

    var body: some View {
        let state = UnderratedEmptyState.of(reason: feedService.underratedEmptyReason, building: building)
        VStack(spacing: 10) {
            switch state.action {
            case .refreshFeed:
                Button {
                    feedService.refresh()
                } label: {
                    DvmEmptyButtonLabel(icon: "arrow.clockwise", title: String(localized: "feed.action.refresh"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("underrated.refreshFeed")
            case .buildWiderNetwork:
                Button {
                    jobs.run(ImportJobs.widerNetwork)
                } label: {
                    DvmEmptyButtonLabel(icon: "globe", title: UnderratedEmptyState.buildTitle)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("underrated.buildWiderNetwork")
            case .buildingWiderNetwork:
                DvmEmptyButtonLabel(icon: nil, title: UnderratedEmptyState.buildingTitle, busy: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("underrated.buildingWiderNetwork")
            }
            if let refusal = jobs.runRefusal, state.action != .refreshFeed {
                Text(refusal)
                    .font(.appSystem(size: 12))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear { jobs.refresh() }
        // The job swaps the wider web in when it ends: ask again.
        .onChange(of: building) { wasBuilding, isBuilding in
            if wasBuilding && !isBuilding && feedService.feedMode == .underrated { feedService.refreshAfterContactLoad() }
        }
    }
}
