import Foundation

/// One item for sale in the Marketplace feed.
///
/// Three event shapes carry listings, and the feed shows all of them, as the
/// MyNostrSpace marketplace does:
/// - NIP-15 products (kind 30018): JSON content with `name`, `description`,
///   `images`, `price`, `currency`.
/// - NIP-15 auctions (kind 30020): the same JSON, with `starting_bid` in place
///   of `price`.
/// - NIP-99 classifieds (kind 30402): markdown content, with `title`,
///   `summary`, `image`, `price` and `location` tags.
///
/// Pure Foundation so the parser is unit-tested in MediaLogicTests.
struct MarketListing: Identifiable, Hashable {
    static let productKind = 30018
    static let auctionKind = 30020
    static let classifiedKind = 30402
    static let kinds = [productKind, auctionKind, classifiedKind]

    let id: String
    let pubkey: String
    let kind: Int
    let dTag: String?
    let title: String
    let summary: String
    /// Every image the listing carries, first one is the cover.
    let images: [URL]
    /// The amount as the seller wrote it ("21000", "45.50").
    let price: String
    /// Uppercased currency code ("SATS", "USD"). Empty when the listing gave none.
    let currency: String
    let category: MarketCategory
    let location: String?
    let createdAt: Date
    let content: String
    let tags: [[String]]

    var isAuction: Bool { kind == Self.auctionKind }
    var coverImage: URL? { images.first }

    /// "21,000 sats", "45.50 USD". Sats are grouped; fiat is left as written.
    var priceLabel: String {
        let unit = currency.isEmpty ? "SATS" : currency
        if Self.satUnits.contains(unit) {
            if let amount = Int(price) {
                return "\(Self.groupedFormatter.string(from: NSNumber(value: amount)) ?? price) sats"
            }
            return "\(price) sats"
        }
        return "\(price) \(unit)"
    }

    /// Plebeian Market's page for the listing, keyed by event id the way the
    /// MyNostrSpace marketplace links it.
    var plebeianURL: URL? {
        URL(string: "https://plebeian.market/\(isAuction ? "auction" : "products")/\(id)")
    }

    private static let satUnits: Set<String> = ["SAT", "SATS", "SATOSHI", "SATOSHIS"]

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// Parses an event into a listing, or nil when it is not one worth showing.
    ///
    /// Same bar as MyNostrSpace: a listing needs a title and an image, since
    /// the feed is a grid of photos. Listings marked `status sold` or
    /// `visibility hidden` are dropped too; nobody can buy them.
    init?(id: String, pubkey: String, kind: Int, content: String, createdAt: Date, tags: [[String]]) {
        guard Self.kinds.contains(kind) else { return nil }

        func tag(_ name: String) -> [String]? {
            tags.first { $0.count >= 2 && $0[0] == name }
        }
        func tagValue(_ name: String) -> String? {
            guard let value = tag(name)?[1].trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        var title = ""
        var summary = ""
        var imageStrings: [String] = []
        var price = ""
        var currency = ""
        var isJSON = false

        // NIP-15 puts everything in JSON content. A classified's markdown body
        // is not JSON, so this does nothing for kind 30402.
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            isJSON = true
            // Conduit writes JSON into 30402 content too, with `title`,
            // `summary` and images as `[{"url": …}]`.
            title = (json["name"] as? String) ?? (json["title"] as? String) ?? ""
            summary = (json["description"] as? String) ?? (json["summary"] as? String) ?? ""
            imageStrings = (json["images"] as? [Any])?.compactMap { item in
                (item as? String) ?? ((item as? [String: Any])?["url"] as? String)
            } ?? []
            price = Self.amountString(json["price"] ?? json["starting_bid"]) ?? ""
            currency = (json["currency"] as? String) ?? ""
        } else {
            summary = content
        }

        if title.isEmpty { title = tagValue("title") ?? tagValue("name") ?? "" }
        // Tag-shaped listings (every NIP-99 one, and zap.cooking's 30018s)
        // keep the short blurb in `summary` and the long text in content.
        if !isJSON || summary.isEmpty, let tagSummary = tagValue("summary") {
            summary = tagSummary
        }
        if imageStrings.isEmpty {
            imageStrings = tags.filter { $0.count >= 2 && $0[0] == "image" }.map { $0[1] }
        }
        if price.isEmpty, let priceTag = tag("price") {
            price = priceTag[1]
            if currency.isEmpty, priceTag.count >= 3 { currency = priceTag[2] }
        }

        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = imageStrings.compactMap { string -> URL? in
            guard let url = URL(string: string.trimmingCharacters(in: .whitespaces)),
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            return url
        }

        guard !title.isEmpty, title != "Untitled Product", !images.isEmpty else { return nil }
        if tagValue("status")?.lowercased() == "sold" { return nil }
        // Conduit and Shopstr hide delisted items this way instead of deleting.
        if tagValue("visibility")?.lowercased() == "hidden" { return nil }

        self.id = id
        self.pubkey = pubkey
        self.kind = kind
        self.dTag = tagValue("d")
        self.title = title
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.images = images
        self.price = price.isEmpty ? "?" : price
        self.currency = currency.trimmingCharacters(in: .whitespaces).uppercased()
        self.location = tagValue("location")
        self.createdAt = createdAt
        self.content = content
        self.tags = tags
        self.category = MarketCategory.classify(
            topics: tags.filter { $0.count >= 2 && $0[0] == "t" }.map { $0[1] },
            text: "\(title) \(summary)"
        )
    }

    /// NIP-15 prices are JSON numbers, but some clients write strings.
    private static func amountString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            // Whole numbers without a trailing ".0"; fractions as written.
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
            return number.stringValue
        default:
            return nil
        }
    }
}

/// The category chips the Marketplace feed filters by.
///
/// The list and the keyword rules come from the MyNostrSpace marketplace.
/// One change from it: MyNostrSpace matched keywords anywhere inside the
/// description, so "start" counted as Art and "party" as Art too, and most
/// listings with "sats" in the text landed in Bitcoin. Here a `t` tag still
/// matches by substring (sellers tag `bitcoin-hardware`), but the title and
/// description only match whole words.
enum MarketCategory: String, CaseIterable, Hashable {
    case bitcoin = "Bitcoin"
    case art = "Art"
    case clothing = "Clothing"
    case foodAndDrink = "Food & Drink"
    case homeAndTechnology = "Home & Technology"
    case healthAndBeauty = "Health & Beauty"
    case sportsAndOutside = "Sports & Outside"
    case services = "Services"
    case books = "Books"
    case pets = "Pets"
    case collectibles = "Collectibles"
    case entertainment = "Entertainment"
    case accessories = "Accessories"
    case shoes = "Shoes"
    case digital = "Digital"
    case physical = "Physical"
    case resale = "Resale"
    case exchange = "Exchange"
    case other = "Other"

    /// First match wins, in this order. Same as MyNostrSpace except that Shoes
    /// is checked before Clothing (Clothing listed "shoes", so Shoes could
    /// never match), "digital" is no longer an Art word (Digital never matched
    /// either), and Services drops "work" and "dev", which as whole words
    /// match far more descriptions than services.
    private static let rules: [(MarketCategory, [String])] = [
        (.bitcoin, ["bitcoin", "btc", "sats", "crypto", "miner", "asic", "hardware wallet", "signing device"]),
        (.art, ["art", "print", "painting", "drawing", "sculpture", "nft", "poster"]),
        (.shoes, ["shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "sandal", "sandals"]),
        (.clothing, ["clothing", "shirt", "t-shirt", "hat", "hoodie", "apparel", "fashion", "wear"]),
        (.foodAndDrink, ["food", "drink", "coffee", "tea", "beef", "meat", "steak", "wine", "beer"]),
        (.homeAndTechnology, ["technology", "tech", "electronics", "computer", "phone", "gadget", "software", "hardware", "home"]),
        (.healthAndBeauty, ["health", "beauty", "soap", "cosmetic", "supplement", "vitamin", "skin"]),
        (.sportsAndOutside, ["sports", "outside", "outdoor", "camping", "hiking", "gear"]),
        (.services, ["service", "freelance", "job", "consulting", "design"]),
        (.books, ["book", "books", "ebook", "reading", "novel", "magazine"]),
        (.pets, ["pet", "pets", "dog", "cat", "animal"]),
        (.collectibles, ["collectible", "rare", "vintage", "antique", "coin", "coins"]),
        (.entertainment, ["entertainment", "movie", "film", "music", "game", "toy"]),
        (.accessories, ["accessory", "accessories", "jewelry", "bag", "wallet", "watch"]),
        (.digital, ["digital", "code", "license"]),
        (.physical, ["physical"]),
        (.resale, ["resale", "used", "secondhand"]),
        (.exchange, ["exchange", "swap", "trade"]),
    ]

    static func classify(topics: [String], text: String) -> MarketCategory {
        let lowerTopics = topics.map { $0.lowercased() }
        let words = wordSet(text.lowercased())
        let lowerText = " " + text.lowercased() + " "
        for (category, keywords) in rules {
            for keyword in keywords {
                if lowerTopics.contains(where: { $0.contains(keyword) }) { return category }
                // Two-word keywords ("hardware wallet") match as a phrase.
                if keyword.contains(" ") {
                    if lowerText.contains(" \(keyword) ") { return category }
                } else if words.contains(keyword) {
                    return category
                }
            }
        }
        return .other
    }

    private static func wordSet(_ text: String) -> Set<String> {
        Set(text.split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init))
    }
}
