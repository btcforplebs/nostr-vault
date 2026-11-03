import SwiftUI

/// Flag a link: a public NIP-32 label (spam, scam, nsfw or good) about
/// someone else's site.
struct LabelReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var label: String?
    @State private var comment = ""
    @State private var publishing = false
    @State private var error: String?

    private var url: String? { intent.source.url }

    var body: some View {
        Form {
            Section("Link") {
                if let title = intent.source.title, !title.isEmpty { Text(title) }
                Text(url ?? "No link was shared.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Section("Label") {
                Picker("Label", selection: $label) {
                    Text("Choose…").tag(String?.none)
                    ForEach(LabelShareTags.labels, id: \.self) { Text(Self.title($0)).tag(String?.some($0)) }
                }
            }
            Section("Comment (optional)") {
                TextField("Why", text: $comment, axis: .vertical).lineLimit(1...4)
            }
            SharePortalAccountSection(intent: intent)
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            SharePortalActionButton(title: "Publish", busy: publishing,
                                    enabled: SharePortalAccountSection.isReady(intent) && label != nil && url != nil,
                                    footer: "Labels are public and name this site. Anyone can see that you labelled it.") { publish() }
        }
    }

    static func title(_ label: String) -> String {
        switch label {
        case "spam": return "Spam"
        case "scam": return "Scam"
        case "nsfw": return "Not safe for work"
        case "good": return "Good"
        default: return label
        }
    }

    private func publish() {
        guard let label, let url else { return }
        publishing = true
        error = nil
        Task {
            do {
                try await LabelPublisher.publish(label: label, url: url, comment: comment, for: intent)
                close()
            } catch {
                self.error = error.localizedDescription
                publishing = false
            }
        }
    }
}
