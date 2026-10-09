import Foundation

/// A NIP-99 classified listing (kind 30402) as the Sell composer writes it.
/// Kept apart from the view so the tags can be tested, and so a listing we
/// publish reads back through `MarketListing` exactly as it was entered.
struct ListingDraft {
    var title: String
    var summary: String
    var description: String
    var price: String
    var currency: String
    var category: MarketCategory
    var location: String
    var imageURLs: [URL]
    /// Reused when editing, so the listing keeps its address.
    var dTag: String?

    /// Currencies offered in the composer. "SATS" is what Shopstr and
    /// Plebeian write for bitcoin prices; the rest are ISO 4217.
    static let currencies = ["SATS", "USD", "EUR", "CAD", "GBP"]

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Digits and at most one decimal point, with grouping commas dropped.
    var normalizedPrice: String? {
        let cleaned = trimmed(price).replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, Double(cleaned) != nil, !cleaned.hasPrefix("-") else { return nil }
        return cleaned
    }

    /// What the composer needs before Publish is enabled. `MarketListing`
    /// drops listings without a title or a photo, so these are required here
    /// too; a listing the grid would hide is not worth publishing.
    var isComplete: Bool {
        !trimmed(title).isEmpty && normalizedPrice != nil && !imageURLs.isEmpty
    }

    func content() -> String { trimmed(description) }

    func tags(publishedAt: Int, newDTag: () -> String = { UUID().uuidString.lowercased() }) -> [[String]] {
        var tags: [[String]] = [
            ["d", dTag ?? newDTag()],
            ["title", trimmed(title)],
        ]
        let summary = trimmed(self.summary)
        if !summary.isEmpty { tags.append(["summary", summary]) }
        tags.append(["published_at", String(publishedAt)])
        if let price = normalizedPrice { tags.append(["price", price, currency]) }
        let location = trimmed(self.location)
        if !location.isEmpty { tags.append(["location", location]) }
        for url in imageURLs { tags.append(["image", url.absoluteString]) }
        // Shopstr and MyNostrSpace file listings by these exact names, and
        // `MarketCategory.classify` reads them back to the same category.
        if category != .other { tags.append(["t", category.rawValue]) }
        tags.append(["status", "active"])
        return tags
    }
}
