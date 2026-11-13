import SwiftUI

/// All's one line for the likes and reposts from outside your web
/// (VaultActivity+OutsideFold): "N from outside your web", which opens the
/// "Outside your web" filter where they are listed.
struct VaultOutsideFoldRow: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.appSystem(size: 13, weight: .semibold))
                Text(VaultActivity.outsideLabel(count))
                    .font(.appSystem(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.appSystem(size: 11, weight: .semibold))
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows likes and reposts from people outside your web of trust")
    }
}
