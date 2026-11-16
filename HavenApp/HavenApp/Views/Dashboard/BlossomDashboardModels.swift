import SwiftUI

// MARK: - Blossom Stats

struct BlossomStats {
    var totalFiles: Int = 0
    var totalSize: Int64 = 0
    var mirrorCount: Int = 0
    var backedUpCount: Int = 0

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var backupPercentage: Int {
        guard totalFiles > 0 else { return 0 }
        return Int((Double(backedUpCount) / Double(totalFiles)) * 100)
    }
}

// MARK: - Mirror Info

struct MirrorInfo: Identifiable {
    let id: UUID
    let url: String
    let host: String
    var isHealthy: Bool?
    var responseTime: Int?
    var fileCount: Int?
}

// MARK: - Blossom Activity Log

struct BlossomActivityLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: LogLevel

    enum LogLevel {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: return .blue
            case .success: return .green
            case .warning: return .orange
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Activity Log View

struct ActivityLogView: View {
    let logs: [BlossomActivityLog]
    let syncMessage: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if !syncMessage.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(syncMessage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.accentText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }

                if logs.isEmpty && syncMessage.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No recent activity")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(logs) { log in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: log.level.icon)
                                .font(.system(size: 10))
                                .foregroundColor(log.level.color)

                            Text(logTimestamp(log.timestamp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text(log.message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
