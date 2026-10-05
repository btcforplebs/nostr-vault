package com.nostrvault.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.text.NumberFormat
import java.util.Locale

/**
 * One item for sale in the Marketplace feed. Mirrors MarketListing.swift.
 *
 * Three event shapes carry listings, as in the MyNostrSpace marketplace:
 * NIP-15 products (30018) and auctions (30020) with JSON content, and NIP-99
 * classifieds (30402) with tags. Live relays also carry tag-shaped 30018s
 * (zap.cooking) and JSON 30402s (Conduit), so both paths run for every kind.
 */
data class MarketListing(
    val id: String,
    val pubkey: String,
    val kind: Int,
    val dTag: String?,
    val title: String,
    val summary: String,
    /** Every image the listing carries; the first is the cover. */
    val images: List<String>,
    /** The amount as the seller wrote it ("21000", "45.50"), or "?". */
    val price: String,
    /** Uppercased currency code, empty when the listing gave none. */
    val currency: String,
    val category: MarketCategory,
    val location: String?,
    val createdAt: Long,
    val content: String,
    val tags: List<List<String>>,
) {
    val isAuction: Boolean get() = kind == AUCTION_KIND
    val coverImage: String? get() = images.firstOrNull()

    /** "21,000 sats", "45.50 USD". Sats are grouped; fiat is left as written. */
    val priceLabel: String
        get() {
            val unit = currency.ifEmpty { "SATS" }
            if (unit in SAT_UNITS) {
                val amount = price.toLongOrNull() ?: return "$price sats"
                return "${NumberFormat.getIntegerInstance(Locale.US).format(amount)} sats"
            }
            return "$price $unit"
        }

    /** Plebeian Market's page, keyed by event id as MyNostrSpace links it. */
    val plebeianUrl: String
        get() = "https://plebeian.market/${if (isAuction) "auction" else "products"}/$id"

    /** The opening line of Message seller: which listing, and its Plebeian link. */
    val messageToSeller: String
        get() = "Hi! I'm interested in ${if (title.isEmpty()) "your listing" else "“$title”"}.\n$plebeianUrl"

    companion object {
        const val PRODUCT_KIND = 30018
        const val AUCTION_KIND = 30020
        const val CLASSIFIED_KIND = 30402
        val KINDS = listOf(PRODUCT_KIND, AUCTION_KIND, CLASSIFIED_KIND)

        private val SAT_UNITS = setOf("SAT", "SATS", "SATOSHI", "SATOSHIS")
        private val json = Json { ignoreUnknownKeys = true; isLenient = true }

        /**
         * Parses an event, or null when it is not worth showing: no title, no
         * image (the feed is a grid of photos), or marked sold or hidden.
         */
        fun parse(
            id: String,
            pubkey: String,
            kind: Int,
            content: String,
            createdAt: Long,
            tags: List<List<String>>,
        ): MarketListing? {
            if (kind !in KINDS) return null

            fun tag(name: String) = tags.firstOrNull { it.size >= 2 && it[0] == name }
            fun tagValue(name: String) = tag(name)?.get(1)?.trim()?.ifEmpty { null }

            var title = ""
            var summary = ""
            var imageStrings = emptyList<String>()
            var price = ""
            var currency = ""

            val obj = runCatching { json.parseToJsonElement(content) as? JsonObject }.getOrNull()
            if (obj != null) {
                // Conduit writes `title`/`summary` and images as [{"url": …}].
                title = obj.string("name") ?: obj.string("title") ?: ""
                summary = obj.string("description") ?: obj.string("summary") ?: ""
                imageStrings = (obj["images"] as? JsonArray)?.mapNotNull { item ->
                    (item as? JsonPrimitive)?.contentOrNull
                        ?: ((item as? JsonObject)?.get("url") as? JsonPrimitive)?.contentOrNull
                } ?: emptyList()
                price = amountString(obj["price"] ?: obj["starting_bid"]) ?: ""
                currency = obj.string("currency") ?: ""
            } else {
                summary = content
            }

            if (title.isEmpty()) title = tagValue("title") ?: tagValue("name") ?: ""
            // Tag-shaped listings keep the short blurb in `summary`.
            if (obj == null || summary.isEmpty()) tagValue("summary")?.let { summary = it }
            if (imageStrings.isEmpty()) {
                imageStrings = tags.filter { it.size >= 2 && it[0] == "image" }.map { it[1] }
            }
            if (price.isEmpty()) {
                tag("price")?.let { priceTag ->
                    price = priceTag[1]
                    if (currency.isEmpty() && priceTag.size >= 3) currency = priceTag[2]
                }
            }

            title = title.trim()
            val images = imageStrings.map { it.trim() }
                .filter { it.startsWith("https://") || it.startsWith("http://") }

            if (title.isEmpty() || title == "Untitled Product" || images.isEmpty()) return null
            if (tagValue("status")?.lowercase() == "sold") return null
            // Conduit and Shopstr hide delisted items this way instead of deleting.
            if (tagValue("visibility")?.lowercase() == "hidden") return null

            return MarketListing(
                id = id,
                pubkey = pubkey,
                kind = kind,
                dTag = tagValue("d"),
                title = title,
                summary = summary.trim(),
                images = images,
                price = price.ifEmpty { "?" },
                currency = currency.trim().uppercase(),
                category = MarketCategory.classify(
                    topics = tags.filter { it.size >= 2 && it[0] == "t" }.map { it[1] },
                    text = "$title $summary",
                ),
                location = tagValue("location"),
                createdAt = createdAt,
                content = content,
                tags = tags,
            )
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

        /** NIP-15 prices are JSON numbers, but some clients write strings. */
        private fun amountString(value: JsonElement?): String? {
            val p = value as? JsonPrimitive ?: return null
            if (p.isString) return p.content.trim().ifEmpty { null }
            val d = p.doubleOrNull ?: return null
            return if (d == Math.rint(d) && kotlin.math.abs(d) < 1e15) d.toLong().toString() else p.content
        }
    }
}

/**
 * Category chips for the Marketplace feed. Same list and rules as
 * MarketCategory in Swift: `t` tags match by substring, title and description
 * only by whole word, first match wins in declaration order.
 */
enum class MarketCategory(val displayName: String, private val keywords: List<String>) {
    BITCOIN("Bitcoin", listOf("bitcoin", "btc", "sats", "crypto", "miner", "asic", "hardware wallet", "signing device")),
    ART("Art", listOf("art", "print", "painting", "drawing", "sculpture", "nft", "poster")),
    SHOES("Shoes", listOf("shoe", "shoes", "sneaker", "sneakers", "boot", "boots", "sandal", "sandals")),
    CLOTHING("Clothing", listOf("clothing", "shirt", "t-shirt", "hat", "hoodie", "apparel", "fashion", "wear")),
    FOOD_AND_DRINK("Food & Drink", listOf("food", "drink", "coffee", "tea", "beef", "meat", "steak", "wine", "beer")),
    HOME_AND_TECHNOLOGY("Home & Technology", listOf("technology", "tech", "electronics", "computer", "phone", "gadget", "software", "hardware", "home")),
    HEALTH_AND_BEAUTY("Health & Beauty", listOf("health", "beauty", "soap", "cosmetic", "supplement", "vitamin", "skin")),
    SPORTS_AND_OUTSIDE("Sports & Outside", listOf("sports", "outside", "outdoor", "camping", "hiking", "gear")),
    SERVICES("Services", listOf("service", "freelance", "job", "consulting", "design")),
    BOOKS("Books", listOf("book", "books", "ebook", "reading", "novel", "magazine")),
    PETS("Pets", listOf("pet", "pets", "dog", "cat", "animal")),
    COLLECTIBLES("Collectibles", listOf("collectible", "rare", "vintage", "antique", "coin", "coins")),
    ENTERTAINMENT("Entertainment", listOf("entertainment", "movie", "film", "music", "game", "toy")),
    ACCESSORIES("Accessories", listOf("accessory", "accessories", "jewelry", "bag", "wallet", "watch")),
    DIGITAL("Digital", listOf("digital", "code", "license")),
    PHYSICAL("Physical", listOf("physical")),
    RESALE("Resale", listOf("resale", "used", "secondhand")),
    EXCHANGE("Exchange", listOf("exchange", "swap", "trade")),
    OTHER("Other", emptyList());

    companion object {
        private val wordSplit = Regex("[^\\p{L}\\p{N}-]+")

        fun classify(topics: List<String>, text: String): MarketCategory {
            val lowerTopics = topics.map { it.lowercase() }
            val lowerText = text.lowercase()
            val words = lowerText.split(wordSplit).filter { it.isNotEmpty() }.toSet()
            val padded = " $lowerText "
            for (category in entries) {
                for (keyword in category.keywords) {
                    if (lowerTopics.any { it.contains(keyword) }) return category
                    if (' ' in keyword) {
                        if (padded.contains(" $keyword ")) return category
                    } else if (keyword in words) {
                        return category
                    }
                }
            }
            return OTHER
        }
    }
}

/** The listing as a note, so Event Info (relays, raw JSON) can open on it. */
fun MarketListing.toNote(): FeedNote =
    FeedNote.fromEvent(id, pubkey, content, tags, createdAt, kind)

/**
 * Listings keyed by address, where the newest event at an address decides
 * what shows, even when that event is not a showable listing. Mirrors
 * MarketListingBook in Swift.
 *
 * A seller marks an item sold by re-publishing it under the same address
 * with `status sold`. [MarketListing.parse] refuses that version, so a
 * collection that only stored parsed listings never learned about it and kept
 * showing the older, active one. Not thread-safe; callers hold a lock.
 */
class MarketListingBook {
    private val newestAt = HashMap<String, Long>()
    private val byAddress = HashMap<String, MarketListing>()

    /** Newest-first, ties broken by id so the order is stable. */
    val listings: List<MarketListing>
        get() = byAddress.values.sortedWith(
            compareByDescending<MarketListing> { it.createdAt }.thenByDescending { it.id },
        )

    fun clear() {
        newestAt.clear()
        byAddress.clear()
    }

    /** Feeds one relay event in. Returns true when what the book shows changed. */
    fun insert(id: String, pubkey: String, kind: Int, content: String, createdAt: Long, tags: List<List<String>>): Boolean {
        if (kind !in MarketListing.KINDS) return false
        val dTag = tags.firstOrNull { it.size >= 2 && it[0] == "d" }?.get(1)
        val address = "$kind:$pubkey:${dTag ?: id}"
        val seen = newestAt[address]
        if (seen != null && seen >= createdAt) return false
        newestAt[address] = createdAt

        val listing = MarketListing.parse(id, pubkey, kind, content, createdAt, tags)
        val hadListing = byAddress.containsKey(address)
        if (listing != null) byAddress[address] = listing else byAddress.remove(address)
        return listing != null || hadListing
    }
}

/**
 * A NIP-99 classified (kind 30402) as the Sell composer writes it. Port of
 * ListingDraft.swift: same tags in the same order, so a listing posted from
 * Android reads back through [MarketListing.parse] exactly as entered, and
 * Shopstr files it under the same category.
 */
data class ListingDraft(
    val title: String,
    val summary: String = "",
    val description: String = "",
    val price: String,
    val currency: String = "SATS",
    val category: MarketCategory = MarketCategory.OTHER,
    val location: String = "",
    val imageUrls: List<String> = emptyList(),
    /** Reused when editing, so the listing keeps its address. */
    val dTag: String? = null,
) {
    /** Digits and at most one decimal point, with grouping commas dropped. */
    val normalizedPrice: String?
        get() {
            val cleaned = price.trim().replace(",", "")
            if (cleaned.isEmpty() || cleaned.startsWith("-") || cleaned.toDoubleOrNull() == null) return null
            return cleaned
        }

    /** Title, price and a photo: the grid hides a listing without them. */
    val isComplete: Boolean
        get() = title.isNotBlank() && normalizedPrice != null && imageUrls.isNotEmpty()

    fun content(): String = description.trim()

    fun tags(publishedAt: Long, newDTag: () -> String = { java.util.UUID.randomUUID().toString().lowercase() }): List<List<String>> {
        val tags = mutableListOf(listOf("d", dTag ?: newDTag()), listOf("title", title.trim()))
        summary.trim().takeIf { it.isNotEmpty() }?.let { tags += listOf("summary", it) }
        tags += listOf("published_at", publishedAt.toString())
        normalizedPrice?.let { tags += listOf("price", it, currency) }
        location.trim().takeIf { it.isNotEmpty() }?.let { tags += listOf("location", it) }
        imageUrls.forEach { tags += listOf("image", it) }
        // Shopstr and MyNostrSpace file listings by these exact names, and
        // MarketCategory.classify reads them back to the same category.
        if (category != MarketCategory.OTHER) tags += listOf("t", category.displayName)
        tags += listOf("status", "active")
        return tags
    }

    companion object {
        const val KIND = MarketListing.CLASSIFIED_KIND
        /** "SATS" is what Shopstr and Plebeian write; the rest are ISO 4217. */
        val CURRENCIES = listOf("SATS", "USD", "EUR", "CAD", "GBP")
    }
}
