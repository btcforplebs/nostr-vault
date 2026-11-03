import Foundation

/// Publishes a NIP-32 label (kind 1985) about a link, in our namespace with a
/// fixed list of labels (LabelShareTags). Public.
@MainActor
enum LabelPublisher {
    enum LabelError: LocalizedError {
        case unknownLabel
        var errorDescription: String? { "Pick one of the labels." }
    }

    static func publish(label: String, url: String, comment: String, for intent: NVShareIntent) async throws {
        guard let tags = LabelShareTags.tags(label: label, url: url) else { throw LabelError.unknownLabel }
        try await SharePortalPosting.publish(kind: LabelShareTags.kind,
                                             content: comment.trimmingCharacters(in: .whitespacesAndNewlines),
                                             tags: tags, for: intent)
    }
}
