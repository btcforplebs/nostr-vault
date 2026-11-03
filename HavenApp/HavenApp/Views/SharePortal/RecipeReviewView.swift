import SwiftUI

/// Recipe: the page's recipe (its JSON-LD), saved as a recipe draft for the
/// recipe composer. Nothing is published.
struct RecipeReviewView: View {
    let intent: NVShareIntent
    let close: () -> Void

    @State private var fields = RecipeLdParser.Fields()
    @State private var loading = true
    @State private var foundRecipe = false
    @State private var saved = false
    @State private var error: String?
    /// The saved draft, open in the editor.
    @State private var editing: ComposerDraft?

    var body: some View {
        Form {
            if loading {
                Section { HStack { ProgressView(); Text("Reading the recipe…").foregroundStyle(.secondary) } }
            } else {
                if !foundRecipe {
                    Section { Text("This page doesn't describe a recipe Nostr Vault can read. You can still fill it in.").font(.footnote) }
                }
                Section("Recipe") {
                    TextField("Title", text: $fields.title)
                    TextField("Summary", text: $fields.summary, axis: .vertical)
                    TextField("Prep time", text: $fields.prepTime)
                    TextField("Cook time", text: $fields.cookTime)
                    TextField("Servings", text: $fields.servings)
                }
                Section("Ingredients, one per line") { TextEditor(text: $fields.ingredients).frame(minHeight: 100) }
                Section("Directions, one per line") { TextEditor(text: $fields.directions).frame(minHeight: 100) }
                Section("Categories") { TextField("Categories", text: $fields.categories) }
                SharePortalAccountSection(intent: intent, title: "Draft for")
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if saved {
                    Section {
                        Label("Saved. It is under Drafts in New recipe.", systemImage: "checkmark.circle.fill")
                        Button("Done", action: close)
                    }
                } else {
                    SharePortalActionButton(title: "Open in editor", busy: false,
                                            enabled: SharePortalAccountSection.isReady(intent),
                                            footer: nil) { save(open: true) }
                    SharePortalActionButton(title: "Save draft", busy: false, enabled: true,
                                            footer: "Saved on this device only. Nothing is posted.") { save(open: false) }
                }
            }
        }
        // However the editor closes, the share is done: the draft is saved.
        .sheet(item: $editing, onDismiss: close) { draft in
            LongFormComposeView(flavor: .recipe, opening: draft, onDismiss: { editing = nil })
                .environmentObject(NostrService.shared)
                .environmentObject(ConfigService.shared)
        }
        .task {
            guard loading else { return }
            let html = await SharePageFetcher.html(intent.source.url) ?? ""
            fields = RecipeLdParser.parse(html: html, pageTitle: intent.source.title, url: intent.source.url)
            foundRecipe = ShareLinkedData.first("Recipe", in: html) != nil
            loading = false
        }
    }

    private func save(open: Bool) {
        var draft = ComposerDraft(kind: .recipe)
        draft.title = fields.title
        draft.summary = fields.summary
        draft.prepTime = fields.prepTime
        draft.cookTime = fields.cookTime
        draft.servings = fields.servings
        draft.ingredients = fields.ingredients
        draft.directions = fields.directions
        draft.categories = fields.categories
        draft.body = fields.body
        guard SharePortalPosting.saveDraft(draft, for: intent) else { error = "Couldn't save the draft."; return }
        error = nil
        if open { editing = draft } else { saved = true }
    }
}
