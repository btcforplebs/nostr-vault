import SwiftUI
import PhotosUI

/// Writes a NIP-23 long-form post (kind 30023): an article, or a recipe in
/// the shape zap.cooking publishes so recipe apps and our Recipes feed list it.
struct LongFormComposeView: View {
    enum Flavor { case article, recipe }

    let flavor: Flavor
    var onDismiss: () -> Void
    @EnvironmentObject var nostrService: NostrService
    @EnvironmentObject var configService: ConfigService

    @State private var title = ""
    @State private var summary = ""
    @State private var body_ = ""
    @State private var coverItem: PhotosPickerItem?
    @State private var coverData: Data?
    @State private var coverMIME = "image/jpeg"
    // Recipe fields
    @State private var prepTime = ""
    @State private var cookTime = ""
    @State private var servings = ""
    @State private var ingredients = ""
    @State private var directions = ""
    @State private var categories = ""

    @State private var isPosting = false
    @State private var status: String?
    @State private var error: String?

    private var isRecipe: Bool { flavor == .recipe }

    private var canPost: Bool {
        let hasTitle = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isRecipe {
            return hasTitle && !Self.lines(ingredients).isEmpty && !Self.lines(directions).isEmpty
        }
        return hasTitle && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    cover
                    TextField("Title", text: $title)
                        .font(.headline)
                    TextField(isRecipe ? "Short description" : "Summary (optional)", text: $summary, axis: .vertical)
                        .lineLimit(1...3)
                }
                if isRecipe {
                    Section("Details") {
                        TextField("Prep time, e.g. 15 min", text: $prepTime)
                        TextField("Cook time, e.g. 30 min", text: $cookTime)
                        TextField("Servings", text: $servings)
                            #if os(iOS)
                            .keyboardType(.numbersAndPunctuation)
                            #endif
                    }
                    Section {
                        TextEditor(text: $ingredients)
                            .frame(minHeight: 120)
                    } header: {
                        Text("Ingredients")
                    } footer: {
                        Text("One per line.")
                    }
                    Section {
                        TextEditor(text: $directions)
                            .frame(minHeight: 160)
                    } header: {
                        Text("Directions")
                    } footer: {
                        Text("One step per line. They get numbered for you.")
                    }
                    Section {
                        TextEditor(text: $body_)
                            .frame(minHeight: 80)
                    } header: {
                        Text("Chef's notes (optional)")
                    }
                    Section {
                        TextField("e.g. dinner, vegetarian, dessert", text: $categories)
                    } header: {
                        Text("Categories")
                    } footer: {
                        Text("Comma separated.")
                    }
                } else {
                    Section {
                        TextEditor(text: $body_)
                            .frame(minHeight: 280)
                    } header: {
                        Text("Article")
                    } footer: {
                        Text("Markdown works: # headings, **bold**, - lists, > quotes.")
                    }
                }
                if let status {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(status).foregroundColor(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundColor(.red)
                    }
                }
            }
            .disabled(isPosting)
            .navigationTitle(isRecipe ? "New recipe" : "New article")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .disabled(isPosting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Publish") { publish() }
                        .fontWeight(.bold)
                        .disabled(!canPost || isPosting)
                }
            }
        }
        .onChange(of: coverItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    coverData = data
                    coverMIME = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                }
            }
        }
        .interactiveDismissDisabled(isPosting)
    }

    @ViewBuilder
    private var cover: some View {
        PhotosPicker(selection: $coverItem, matching: .images) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(0.12))
                if let coverData, let image = Self.image(from: coverData) {
                    image
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Label("Add a cover photo", systemImage: "photo")
                        .foregroundColor(.havenPurple)
                }
            }
            .frame(height: 160)
            .clipped()
        }
        .buttonStyle(.plain)
    }

    private static func image(from data: Data) -> Image? {
        #if canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return NSImage(data: data).map { Image(nsImage: $0) }
        #endif
    }

    // MARK: - Publishing

    private func publish() {
        isPosting = true
        error = nil
        Task {
            do {
                var imageURL: URL?
                if let coverData {
                    status = "Uploading cover…"
                    imageURL = try await ModePostPublisher.upload(
                        data: coverData, mimeType: coverMIME,
                        configService: configService, nostrService: nostrService).url
                }
                status = "Publishing…"
                let draft = LongFormDraft(
                    title: title, summary: summary, body: body_, imageURL: imageURL,
                    recipe: isRecipe ? .init(prepTime: prepTime, cookTime: cookTime, servings: servings,
                                             ingredients: ingredients, directions: directions,
                                             categories: categories) : nil)
                try await ModePostPublisher.publish(
                    kind: 30023, content: draft.content(),
                    tags: draft.tags(publishedAt: Int(Date().timeIntervalSince1970)),
                    nostrService: nostrService)
                if isRecipe { RecipeFeedService.shared.refresh() }
                status = nil
                isPosting = false
                onDismiss()
            } catch {
                status = nil
                isPosting = false
                self.error = error.localizedDescription
            }
        }
    }

    static func lines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { line in
                // Pasted lists keep their bullets or numbers; drop them so we
                // don't print "- - 2 eggs" or "1. 1. Preheat".
                var l = Substring(line)
                if let first = l.first, "-*•".contains(first) { l = l.dropFirst() }
                if let dot = l.firstIndex(where: { $0 == "." || $0 == ")" }),
                   l[..<dot].allSatisfy(\.isNumber), !l[..<dot].isEmpty {
                    l = l[l.index(after: dot)...]
                }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }
}

/// The event a long-form composer publishes. Kept apart from the view so the
/// tag and markdown shape can be tested.
struct LongFormDraft {
    struct Recipe {
        var prepTime: String
        var cookTime: String
        var servings: String
        var ingredients: String
        var directions: String
        var categories: String
    }

    var title: String
    var summary: String
    var body: String
    var imageURL: URL?
    var recipe: Recipe?

    /// The `d` tag: a slug of the title, like zap.cooking's, plus a short
    /// random suffix so two posts with the same title don't replace each other.
    var identifier: String {
        "\(Self.slug(title))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "post" : String(out.prefix(60))
    }

    func content() -> String {
        guard let recipe else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var parts: [String] = []
        let notes = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            parts.append("## Chef's notes\n\n\(notes)")
        }
        var details: [String] = []
        let prep = recipe.prepTime.trimmingCharacters(in: .whitespaces)
        let cook = recipe.cookTime.trimmingCharacters(in: .whitespaces)
        let serves = recipe.servings.trimmingCharacters(in: .whitespaces)
        if !prep.isEmpty { details.append("- ⏲️ Prep time: \(prep)") }
        if !cook.isEmpty { details.append("- 🍳 Cook time: \(cook)") }
        if !serves.isEmpty { details.append("- 🍽️ Servings: \(serves)") }
        if !details.isEmpty {
            parts.append("## Details\n\n" + details.joined(separator: "\n"))
        }
        let ingredients = LongFormComposeView.lines(recipe.ingredients).map { "- \($0)" }
        parts.append("## Ingredients\n\n" + ingredients.joined(separator: "\n"))
        let steps = LongFormComposeView.lines(recipe.directions).enumerated().map { "\($0.offset + 1). \($0.element)" }
        parts.append("## Directions\n\n" + steps.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    func tags(publishedAt: Int) -> [[String]] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var tags: [[String]] = [["d", identifier], ["title", trimmedTitle]]
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty { tags.append(["summary", trimmedSummary]) }
        if let imageURL { tags.append(["image", imageURL.absoluteString]) }
        tags.append(["published_at", String(publishedAt)])
        var topics: [String] = []
        if let recipe {
            topics.append("zapcooking")
            topics.append("nostrcooking")
            for category in recipe.categories.split(separator: ",") {
                let slug = Self.slug(String(category))
                if slug != "post" { topics.append("zapcooking-\(slug)") }
            }
        }
        topics.append(contentsOf: NoteTagging.hashtagTags(in: "\(trimmedTitle) \(body)").map { $0[1] })
        var seen = Set<String>()
        for topic in topics where seen.insert(topic).inserted {
            tags.append(["t", topic])
        }
        return tags
    }
}
