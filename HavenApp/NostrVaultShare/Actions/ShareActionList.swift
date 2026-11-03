import SwiftUI

/// The ranked actions for what was shared, most likely first. Only actions
/// the app can finish are passed in (NVShareActionAvailability).
struct ShareActionList: View {
    let input: NVShareInput
    let actions: [NVShareAction]
    let pick: (NVShareAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let what = summary {
                Text(what)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if actions.isEmpty {
                Text("Nostr Vault can't do anything with this yet.")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(actions, id: \.self) { action in
                Button { pick(action) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.systemImage).frame(width: 24)
                        Text(action.title).font(.body)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var summary: String? {
        if let title = input.title, !title.isEmpty { return title }
        return NVShareClassifier.webURL(of: input)
    }
}
