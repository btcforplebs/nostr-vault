import SwiftUI

/// Article clip: a quote and a link, saved as an article draft. The editor
/// opens it later from the article composer's Drafts. Nothing is published.
struct ArticleClipReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @State private var title = ""
    @State private var bodyText = ""
    @State private var started = false
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("Title") { TextField("Title", text: $title) }
            Section {
                TextEditor(text: $bodyText).frame(minHeight: 160)
            } header: {
                Text("Draft")
            } footer: {
                Text("A quote and a link back, not a copy of the page.")
            }
            SharePortalAccountSection(intent: intent, title: "Draft for")
            if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            if saved {
                Section {
                    Label("Saved. It is under Drafts in New article.", systemImage: "checkmark.circle.fill")
                    Button("Done", action: close)
                }
            } else {
                SharePortalActionButton(title: "Save draft", busy: false,
                                        enabled: !title.trimmingCharacters(in: .whitespaces).isEmpty || !bodyText.isEmpty,
                                        footer: "Saved on this device only. Nothing is posted.") { save() }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            let t = ArticleClipDraft.title(intent.source.title, url: intent.source.url)
            title = t
            bodyText = ArticleClipDraft.body(title: t, url: intent.source.url, selection: intent.source.selection)
        }
    }

    private func save() {
        var draft = ComposerDraft(kind: .article)
        draft.title = title
        draft.body = bodyText
        if SharePortalPosting.saveDraft(draft, for: intent) { saved = true; error = nil }
        else { error = "Couldn't save the draft." }
    }
}
