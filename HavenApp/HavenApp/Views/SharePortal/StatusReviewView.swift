import SwiftUI

/// "Share what I'm playing": a NIP-38 status that everyone can see and that
/// expires on its own.
struct StatusReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @ObservedObject private var config = ConfigService.shared
    @State private var text = ""
    @State private var seconds = StatusShareTags.defaultSeconds
    @State private var started = false
    @State private var publishing = false
    @State private var error: String?

    private var url: String? { intent.source.url }

    var body: some View {
        Form {
            Section("Status") {
                TextField("What you're playing", text: $text, axis: .vertical).lineLimit(1...3)
                if let url { Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Section("Show it for") {
                Picker("Show it for", selection: $seconds) {
                    ForEach(StatusShareTags.durations, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                .pickerStyle(.segmented)
            }
            SharePortalAccountSection(intent: intent)
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            SharePortalActionButton(title: "Publish", busy: publishing,
                                    enabled: SharePortalAccountSection.isReady(intent)
                                        && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    footer: "Your status is public: anyone who follows you can see it until it expires.") { publish() }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let title = intent.source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            text = title.isEmpty ? (url ?? "") : title
        }
    }

    private func publish() {
        publishing = true
        error = nil
        Task {
            do {
                try await UserStatusPublisher.publish(text: text, url: url, lasting: seconds, for: intent)
                close()
            } catch {
                self.error = error.localizedDescription
                publishing = false
            }
        }
    }
}
