import SwiftUI

// MARK: - Mirror Status Section

struct MirrorStatusSection: View {
    let mirrors: [MirrorInfo]
    @Binding var isExpanded: Bool
    let onTest: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text("\(mirrors.count) configured")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.platformSecondaryGroupedBackground)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(mirrors) { mirror in
                    MirrorRow(mirror: mirror)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Mirror Row

struct MirrorRow: View {
    let mirror: MirrorInfo

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(mirror.isHealthy == true ? Color.green : mirror.isHealthy == false ? Color.red.opacity(0.7) : Color.yellow)
                .frame(width: 6, height: 6)

            Text(mirror.host)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.8))
                .lineLimit(1)

            Spacer()

            if let responseTime = mirror.responseTime {
                Text("\(responseTime)ms")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.green.opacity(0.7))
            } else {
                Text(mirror.isHealthy == nil ? "Pending" : (mirror.isHealthy == true ? "Healthy" : "Offline"))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(mirror.isHealthy == nil ? .yellow.opacity(0.7) : (mirror.isHealthy == true ? .green.opacity(0.7) : .red.opacity(0.5)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(
            Rectangle()
                .fill(Color.ink.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Storage Breakdown Section

struct StorageBreakdownSection: View {
    let stats: BlossomStats

    var body: some View {
        VStack(spacing: 1) {
            BlossomStorageRow(label: "Total Files", value: "\(stats.totalFiles)", icon: "doc.fill", color: .blue)
            BlossomStorageRow(label: "Total Size", value: stats.formattedSize, icon: "internaldrive.fill", color: .havenPurple)
            BlossomStorageRow(label: "Backed Up", value: "\(stats.backedUpCount) (\(stats.backupPercentage)%)", icon: "checkmark.seal.fill", color: .green)
            BlossomStorageRow(label: "Needs Backup", value: "\(stats.totalFiles - stats.backedUpCount)", icon: "exclamationmark.triangle.fill", color: .orange)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Blossom Storage Row

struct BlossomStorageRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(color)
                .frame(width: 20)

            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformSecondaryGroupedBackground)
        .overlay(
            Rectangle()
                .fill(Color.ink.opacity(0.03))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}
