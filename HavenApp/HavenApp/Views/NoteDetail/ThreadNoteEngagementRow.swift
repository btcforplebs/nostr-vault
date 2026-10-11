import SwiftUI

// MARK: - Thread Note Engagement Row (reusable compact row for expanded view)

struct ThreadNoteEngagementRow: View {
    let reactions: [(emoji: String, count: Int)]
    let zapCount: Int
    let zapSats: Int64
    let repostCount: Int

    private var hasContent: Bool {
        !reactions.isEmpty || zapCount > 0 || repostCount > 0
    }

    var body: some View {
        if hasContent {
            HStack(spacing: 8) {
                if !reactions.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(reactions.prefix(3), id: \.emoji) { group in
                            HStack(spacing: 1) {
                                Text(group.emoji).font(.appSystem(size: 11))
                                Text("\(group.count)")
                                    .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        if reactions.count > 3 {
                            Text("+\(reactions.count - 3)")
                                .font(.appSystem(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if zapCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                        Text(formatSats(zapSats))
                            .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                if repostCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.2.squarepath")
                            .font(.appSystem(size: 8, weight: .bold))
                            .foregroundColor(.green)
                        Text("\(repostCount)")
                            .font(.appSystem(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(6)
                }

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func formatSats(_ sats: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? "\(sats)"
    }
}
