import Foundation
import Combine

@MainActor
class PriceService: ObservableObject {
    static let shared = PriceService()

    @Published var btcUsdPrice: Double?
    @Published var isLoadingPrice = false
    private var priceCache: (price: Double, timestamp: Date)?
    private let cacheDuration: TimeInterval = 300 // 5 minutes

    private init() {}

    func fetchBTCPrice() async {
        await MainActor.run { isLoadingPrice = true }

        // Check cache
        if let cached = priceCache, Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            await MainActor.run {
                btcUsdPrice = cached.price
                isLoadingPrice = false
            }
            return
        }

        // Try Kraken first
        if let price = await fetchFromKraken() {
            priceCache = (price, Date())
            await MainActor.run {
                btcUsdPrice = price
                isLoadingPrice = false
            }
            return
        }

        // Fall back to Bitstamp
        if let price = await fetchFromBitstamp() {
            priceCache = (price, Date())
            await MainActor.run {
                btcUsdPrice = price
                isLoadingPrice = false
            }
            return
        }

        await MainActor.run { isLoadingPrice = false }
    }

    private func fetchFromKraken() async -> Double? {
        guard let url = URL(string: "https://api.kraken.com/0/public/Ticker?pair=XBTUSD") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let response = try decoder.decode(KrakenResponse.self, from: data)

            if let result = response.result,
               let xbtusd = result["XXBTZUSD"] as? [String: Any],
               let priceArray = xbtusd["c"] as? [String],
               let price = Double(priceArray[0]) {
                return price
            }
        } catch {
            #if DEBUG
            print("Kraken price fetch failed: \(error)")
            #endif
        }
        return nil
    }

    private func fetchFromBitstamp() async -> Double? {
        guard let url = URL(string: "https://www.bitstamp.net/api/v2/ticker/btcusd/") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let response = try decoder.decode(BitstampResponse.self, from: data)

            if let price = Double(response.last) {
                return price
            }
        } catch {
            #if DEBUG
            print("Bitstamp price fetch failed: \(error)")
            #endif
        }
        return nil
    }
}

// MARK: - Models

struct KrakenResponse: Decodable {
    let result: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let result = try container.decodeIfPresent([String: AnyCodable].self, forKey: .result) {
            self.result = result.mapValues { $0.value }
        } else {
            self.result = nil
        }
    }
}

struct BitstampResponse: Decodable {
    let last: String
}

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self) {
            value = stringVal
        } else if let boolVal = try? container.decode(Bool.self) {
            value = boolVal
        } else if let arrayVal = try? container.decode([AnyCodable].self) {
            value = arrayVal.map { $0.value }
        } else if let dictVal = try? container.decode([String: AnyCodable].self) {
            value = dictVal.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}
