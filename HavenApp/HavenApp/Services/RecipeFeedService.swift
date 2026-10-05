import Foundation
import Combine

/// Recipes feed.
///
/// Recipes are ordinary NIP-23 long-form events (kind 30023) tagged
/// `zapcooking` or `nostrcooking`. Unlike Articles they are written by
/// strangers, so they fall outside the `authors: follows` set the device's own
/// relay syncs — this feed therefore talks to external relays directly and
/// keeps its results in memory only. Nothing is written to the owner's relay.
/// Who a recipe feed draws from. Mirrors the Media tab's Following/Global
/// split; Global follows the app-wide Web of Trust shield.
enum RecipeScope: String {
    case following
    case global
}

@MainActor
final class RecipeFeedService: ObservableObject {
    static let shared = RecipeFeedService()

    /// Recipes newest-first, one per `pubkey:d` address.
    @Published private(set) var recipes: [FeedNote] = []
    @Published private(set) var isLoading = false
    /// Set when every relay failed or returned nothing.
    @Published private(set) var loadFailed = false
    /// Selected category chip, or nil for "All".
    @Published var selectedCategory: String?
    /// Following by default. Global is filtered by the Web of Trust shield;
    /// Everyone (unfiltered) is behind the sensitive-content warning.
    @Published private(set) var scope: RecipeScope = .following
    /// True when Following is selected and the owner follows nobody who has
    /// posted a recipe — distinct from "the relays returned nothing".
    @Published private(set) var followSetIsEmpty = false

    /// The `t` tags that mark an event as a recipe.
    static let recipeTopics = ["zapcooking", "nostrcooking"]
    /// Prefix zap.cooking uses for its category tags, e.g. `zapcooking-dessert`.
    private static let categoryPrefix = "zapcooking-"

    private var clients: [WebSocketClient] = []
    private var cancellables = Set<AnyCancellable>()
    private var collected: [String: FeedNote] = [:]
    private var loadTimeout: Timer?
    private var lastLoadedAt: Date?
    /// The scope the cached results belong to, so switching scope always
    /// refetches rather than re-showing the other set.
    private var lastLoadedScope: RecipeScope?
    /// The shield setting the cached results were fetched under.
    private var lastLoadedEveryone: Bool?
    /// Who Global may show this load; nil = everyone (see globalTrustSet).
    private var trust: Set<String>?

    /// Results older than this are refetched when the feed is opened again.
    private static let staleAfter: TimeInterval = 10 * 60

    private init() {}

    /// The most common categories in the current results.
    ///
    /// Capped deliberately: a 200-recipe page carries close to 300 distinct
    /// `zapcooking-*` tags (measured against nos.lol, 2026-09-05), most of them
    /// used once. Showing all of them would be a chip bar nobody can scroll.
    /// Ranked by frequency, then alphabetically so equal counts are stable.
    var categories: [String] {
        var counts: [String: Int] = [:]
        for recipe in recipes {
            // A recipe tagged `zapcooking-beef` twice must not count twice.
            var seenInRecipe = Set<String>()
            for topic in recipe.longFormMetadata.topics where topic.hasPrefix(Self.categoryPrefix) {
                let name = String(topic.dropFirst(Self.categoryPrefix.count))
                guard !name.isEmpty, seenInRecipe.insert(name).inserted else { continue }
                counts[name, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(Self.maxCategories)
            .map(\.key)
    }

    /// How many category chips the bar shows.
    private static let maxCategories = 12

    /// Every category present in the current results, uncapped.
    private var allCategories: Set<String> {
        var names = Set<String>()
        for recipe in recipes {
            for topic in recipe.longFormMetadata.topics where topic.hasPrefix(Self.categoryPrefix) {
                let name = String(topic.dropFirst(Self.categoryPrefix.count))
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    /// Recipes after the category chip is applied.
    var visibleRecipes: [FeedNote] {
        guard let category = selectedCategory else { return recipes }
        let tag = Self.categoryPrefix + category
        return recipes.filter { $0.longFormMetadata.topics.contains(tag) }
    }

    /// Loads on first open, and again once the results have gone stale.
    /// Cheap to call from `onAppear`.
    func loadIfNeeded() {
        if isLoading { return }
        if let lastLoadedAt, lastLoadedScope == scope,
           lastLoadedEveryone == ConfigService.shared.config.globalShowsEveryone,
           Date().timeIntervalSince(lastLoadedAt) < Self.staleAfter, !recipes.isEmpty { return }
        refresh()
    }

    /// Switches scope and reloads. Global is filtered by the Web of Trust
    /// shield, so it needs no warning; Everyone has its own.
    func setScope(_ newScope: RecipeScope) {
        guard newScope != scope else { return }
        scope = newScope
        recipes = []
        refresh()
    }

    func refresh() {
        disconnect()
        collected.removeAll()
        loadFailed = false
        followSetIsEmpty = false
        isLoading = true

        let relayURLs = Self.relayURLs
        guard !relayURLs.isEmpty else {
            isLoading = false
            loadFailed = true
            return
        }

        var filter: [String: Any] = [
            "kinds": [30023],
            "#t": Self.recipeTopics,
            "limit": 200
        ]
        if scope == .following {
            let follows = FeedService.shared.followedPubkeys
            guard !follows.isEmpty else {
                // An `authors: []` REQ matches nothing and would look like a
                // dead feed. Say what is actually true instead.
                isLoading = false
                followSetIsEmpty = true
                return
            }
            filter["authors"] = follows
        }
        trust = scope == .global ? FeedService.shared.globalTrustSet() : nil
        lastLoadedEveryone = ConfigService.shared.config.globalShowsEveryone
        let filters = FeedService.trustScopedFilters(filter, trust: trust)
        let subId = "recipes-\(UUID().uuidString.prefix(8))"
        let blocked = ConfigService.shared.activeAccountBlockedHexPubkeys

        for url in relayURLs {
            let client = WebSocketClient()
            client.isTemporary = true
            clients.append(client)

            client.messageSubject
                .receive(on: DispatchQueue.main)
                .sink { [weak self] message in
                    self?.handle(message: message, blocked: blocked)
                }
                .store(in: &cancellables)

            client.connect(url: url)

            // The socket is not open the instant connect() returns; the rest of
            // the feed pipeline uses the same short delay before its REQ.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let req: [Any] = ["REQ", subId] + filters
                if let data = try? JSONSerialization.data(withJSONObject: req),
                   let text = String(data: data, encoding: .utf8) {
                    client.send(text: text)
                }
            }
        }

        // Stop waiting on relays that never answer, and keep whatever arrived.
        loadTimeout?.invalidate()
        loadTimeout = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishLoading() }
        }
    }

    func disconnect() {
        loadTimeout?.invalidate()
        loadTimeout = nil
        cancellables.removeAll()
        clients.forEach { $0.disconnect() }
        clients.removeAll()
    }

    // MARK: - Private

    /// Relays to ask. Recipe authors are strangers, so the owner's own relay
    /// has nothing to contribute here and is deliberately not queried.
    private static var relayURLs: [URL] {
        let configured = ConfigService.shared.config.activeFeedRelays
        let strings = configured.isEmpty ? ["wss://relay.primal.net", "wss://nos.lol"] : configured
        return strings.compactMap { URL(string: $0) }
    }

    private func handle(message: String, blocked: Set<String>) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = json.first as? String else { return }

        if type == "EOSE" {
            publish()
            // One relay reaching EOSE is enough to show results; the others
            // keep streaming into `collected` and republish as they land.
            return
        }

        guard type == "EVENT", json.count >= 3,
              let event = json[2] as? [String: Any],
              let id = event["id"] as? String,
              let pubkey = event["pubkey"] as? String,
              let content = event["content"] as? String,
              let createdAt = event["created_at"] as? Int64,
              let kind = event["kind"] as? Int,
              let tags = event["tags"] as? [[String]],
              kind == 30023,
              !blocked.contains(pubkey),
              trust?.contains(pubkey) != false,
              collected[id] == nil
        else { return }

        if Self.looksLikeTestPost(tags: tags, content: content) { return }

        collected[id] = FeedNote(
            id: id,
            pubkey: pubkey,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            tags: tags,
            kind: kind
        )
        publish()
    }

    /// Client test publishes, not recipes.
    ///
    /// Measured against 500 live zapcooking/nostrcooking events on 2026-09-05:
    /// these two rules drop 20 events, and every one of them is a test post
    /// ("iOS 2.3 Live Publish 1788113645", "E2E Curry", "ZC PR11 Test Bravo",
    /// "Ppp"). No plausible real recipe is lost. The eight timestamped ones
    /// each come from a different pubkey and were the newest events on the
    /// relay, so they sat at the very top of the grid.
    ///
    /// Deliberately narrow. An Ingredients-heading requirement was measured
    /// too and rejected: it also drops real recipes and the Zap Cooking
    /// newsletters, 16 events that people would want to see.
    static func looksLikeTestPost(tags: [[String]], content: String) -> Bool {
        let title = tags.first { $0.count >= 2 && $0[0] == "title" }?[1] ?? ""

        // A unix timestamp in the title means a machine generated it. Real
        // recipe names do not carry a 10-digit number starting with 16-19.
        if title.range(of: "\\b1[6-9][0-9]{8}\\b", options: .regularExpression) != nil {
            return true
        }

        // A recipe needs ingredients and directions. Under 30 words is not one;
        // the shortest real recipe in the sample was 39.
        let words = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return words < 30
    }

    private func publish() {
        recipes = FeedFilterEngine.dedupeAddressable(Array(collected.values))
        if !recipes.isEmpty {
            isLoading = false
            loadFailed = false
            lastLoadedAt = Date()
            lastLoadedScope = scope
        }
        // A category can disappear entirely when results change underneath the
        // chip. Validate against every category present, not the capped chip
        // list — otherwise a selection silently resets the moment more results
        // push it past position 12.
        if let selectedCategory, !allCategories.contains(selectedCategory) {
            self.selectedCategory = nil
        }
    }

    private func finishLoading() {
        isLoading = false
        loadFailed = recipes.isEmpty
        if !recipes.isEmpty {
            lastLoadedAt = Date()
            lastLoadedScope = scope
        }
        disconnect()
    }
}
