import SwiftUI

// MARK: - BlobTypeRow

struct BlobTypeRow: View {
    let label: String
    let icon: String
    let color: Color
    let count: Int
    let size: Int
    let total: Int

    private var sizePercent: Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.ink)
                Text("\(count) \(count == 1 ? "blob" : "blobs")")
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(String(format: "%.1f%%", sizePercent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

// MARK: - StorageRow

struct StorageRow: View {
    let label: String
    let icon: String
    let color: Color
    let size: Int64
    let total: Int64
    /// Buckets that have a detail view of their own become tappable rows.
    var action: (() -> Void)? = nil

    private var sizePercent: Double {
        guard total > 0 else { return 0 }
        return Double(size) / Double(total)
    }

    @ViewBuilder
    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows what is stored here"))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.appSystem(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 24)

            Text(label)
                .font(.appSystem(size: 14, weight: .semibold))
                .foregroundColor(.ink)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.appSystem(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(color)
                Text(String(format: "%.1f%%", sizePercent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 10, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}

// MARK: - KindRow

struct KindRow: View {
    let kind: Int
    let name: String
    let count: Int
    let total: Int

    private var percent: Double {
        guard total > 0 else { return 0 }
        return Double(count) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.appSystem(size: 14, weight: .semibold))
                    .foregroundColor(.ink)
                Text(kind >= 0 ? "kind \(kind)" : "—")
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.appSystem(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(Color.accentText)
                Text(String(format: "%.1f%%", percent * 100))
                    .font(.appSystem(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.platformCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.platformCardBorder, lineWidth: 0.5)
        )
        .cornerRadius(8)
    }
}
