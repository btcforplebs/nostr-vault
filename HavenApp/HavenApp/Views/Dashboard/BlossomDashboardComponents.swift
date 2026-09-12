import SwiftUI

// MARK: - Stats Section

struct StatsSection: View {
    let stats: BlossomStats
    let isLoading: Bool

    var body: some View {
        let columns = [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ]

        LazyVGrid(columns: columns, spacing: 12) {
            StatsCard(
                title: "Total Files",
                value: "\(stats.totalFiles)",
                icon: "photo.on.rectangle",
                color: .blue,
                isLoading: isLoading
            )

            StatsCard(
                title: "Storage Used",
                value: stats.formattedSize,
                icon: "internaldrive.fill",
                color: .havenPurple,
                isLoading: isLoading
            )

            StatsCard(
                title: "Active Mirrors",
                value: "\(stats.mirrorCount)",
                icon: "server.rack",
                color: .green,
                isLoading: isLoading
            )

            StatsCard(
                title: "Backed Up",
                value: "\(stats.backupPercentage)%",
                icon: "checkmark.seal.fill",
                // A finished backup is a healthy state, not a category, so it
                // takes the status colour the rest of the app uses for it.
                color: stats.backupPercentage == 100 ? .havenOnline : .orange,
                isLoading: isLoading
            )
        }
    }
}

// MARK: - Quick Actions Section

struct QuickActionsSection: View {
    let stats: BlossomStats
    @Binding var isPulling: Bool
    @Binding var isPushing: Bool
    let syncProgress: Double
    let syncMessage: String
    let onPull: () -> Void
    let onPush: () -> Void
    let onRefresh: () -> Void

    var needsBackupCount: Int {
        stats.totalFiles - stats.backedUpCount
    }

    var body: some View {
        VStack(spacing: 12) {
            let columns = [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ]

            LazyVGrid(columns: columns, spacing: 10) {
                UnifiedActionButton(
                    icon: "arrow.down.circle",
                    title: "Pull",
                    isLoading: isPulling,
                    action: onPull
                )

                UnifiedActionButton(
                    icon: "arrow.up.circle",
                    title: needsBackupCount > 0 ? "Backup \(needsBackupCount)" : "100% Backed Up",
                    isLoading: isPushing,
                    action: onPush
                )
                .disabled(needsBackupCount == 0)

                UnifiedActionButton(
                    icon: "arrow.clockwise",
                    title: "Refresh",
                    action: onRefresh
                )
            }

            // Inline progress
            if isPulling || isPushing {
                VStack(spacing: 4) {
                    ProgressView(value: syncProgress)
                        .tint(.havenPurple)

                    Text(syncMessage)
                        .font(.appSystem(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(Color.platformSecondaryGroupedBackground)
                .cornerRadius(8)
            }
        }
    }
}

// MARK: - Unified Action Button

struct UnifiedActionButton: View {
    let icon: String
    let title: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: icon)
                        .font(.appSystem(size: 20, weight: .medium))
                        .foregroundColor(.havenPurple)
                }

                Text(title)
                    .font(.appSystem(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .background(Color.platformSecondaryGroupedBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(isHovered ? 0.12 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { hovering in
            withAnimation(Motion.control) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.appSystem(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))

            Spacer()

            if let actionTitle = actionTitle, let action = action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                            .font(.appSystem(size: 10, weight: .medium))
                            .foregroundColor(.havenPurple)
                        Image(systemName: "chevron.right")
                            .font(.appSystem(size: 8, weight: .semibold))
                            .foregroundColor(.havenPurple.opacity(0.7))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
