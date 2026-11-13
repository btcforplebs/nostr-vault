import SwiftUI

/// "Add Genmoji" at the top of the Emoji page (RESEARCH/NV_GENMOJI_STARTER_SET.md,
/// pick S). Only on iOS/iPadOS 18 and macOS 15 (where Genmoji exist) and for
/// an account that can sign; hidden everywhere else.
struct GenmojiAddCard: View {
    @ObservedObject private var configService = ConfigService.shared
    @State private var adding = false

    var body: some View {
        if #available(iOS 18.0, macOS 15.0, *), configService.activeAccountCanSign {
            Button { adding = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "face.smiling.inverse")
                        .font(.appSystem(size: 22))
                        .foregroundColor(.havenPurple)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Genmoji")
                            .font(.appSystem(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Make one with Genmoji, or paste one, and keep it in your own set.")
                            .font(.appSystem(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "plus.circle.fill")
                        .font(.appSystem(size: 22))
                        .foregroundColor(.havenPurple)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.havenPurple.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Add Genmoji")
            .sheet(isPresented: $adding) { GenmojiAddSheet() }
        }
    }
}
