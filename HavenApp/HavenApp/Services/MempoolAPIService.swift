import Foundation

enum MempoolAPIService {
    private static let baseURL = "https://mempool.btcforplebs.com/api"

    struct MempoolTx: Decodable {
        let txid: String
        let vout: [MempoolVout]
    }

    struct MempoolVout: Decodable {
        let scriptpubkey: String
        let scriptpubkey_type: String
        let value: UInt64
    }

    struct TaprootOutput {
        let xOnlyKeyHex: String
        let vout: UInt32
        let amountSats: UInt64
    }

    /// Fetch all P2TR (Taproot) outputs from a transaction.
    static func fetchTaprootOutputs(txid: String) async throws -> [TaprootOutput] {
        guard let url = URL(string: "\(baseURL)/tx/\(txid)") else {
            throw MempoolError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MempoolError.fetchFailed(txid)
        }

        let tx = try JSONDecoder().decode(MempoolTx.self, from: data)

        // P2TR outputs have scriptpubkey_type "v1_p2tr"
        // scriptpubkey format: "5120" + 64-char x-only pubkey hex
        var results: [TaprootOutput] = []
        for (index, output) in tx.vout.enumerated() {
            if output.scriptpubkey_type == "v1_p2tr",
               output.scriptpubkey.count == 68 {
                let xOnlyHex = String(output.scriptpubkey.dropFirst(4))
                results.append(TaprootOutput(
                    xOnlyKeyHex: xOnlyHex,
                    vout: UInt32(index),
                    amountSats: output.value
                ))
            }
        }
        return results
    }

    enum MempoolError: Error, LocalizedError {
        case invalidURL
        case fetchFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid mempool API URL"
            case .fetchFailed(let txid): return "Failed to fetch tx \(txid.prefix(8))..."
            }
        }
    }
}
