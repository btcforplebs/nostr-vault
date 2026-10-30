import Foundation

/// What the sweep will spend and what it will cost. The sweep spends every
/// unspent output at the address, confirmed or not, so the fee grows with
/// each one. Android: PendingSweep.estimatedVsize + MempoolApiService.AddressFunds.
enum BitcoinSweepEstimate {
    /// Outputs at or under this are dust and would not relay.
    static let dustLimit = 546

    /// Size of the sweep: every unspent output into one taproot output. Same
    /// as estimateSweepVsize in haven-go/bitcoin.go: 111 vB for one input,
    /// 169 for two.
    static func vsize(utxoCount: Int) -> Int {
        let inputs = max(1, utxoCount)
        let nonWitness = 10 + 41 * inputs + 43
        let witness = 2 + 66 * inputs
        return (nonWitness * 4 + witness + 3) / 4
    }

    static func fee(utxoCount: Int, feeRate: Int) -> Int {
        vsize(utxoCount: utxoCount) * feeRate
    }

    /// The spendable balance (sats) of an address and how many unspent outputs
    /// make it up, both funded − spent over confirmed and unconfirmed txos.
    struct AddressFunds: Equatable {
        let balanceSats: Int
        let utxoCount: Int

        /// Parses a mempool.space /api/address/<addr> reply; nil when it is
        /// not one. Int is 64-bit, so balances over 21.47 BTC fit.
        init?(mempoolJSON data: Data) {
            struct TxoStats: Decodable {
                let funded_txo_count: Int
                let funded_txo_sum: Int
                let spent_txo_count: Int
                let spent_txo_sum: Int
            }
            struct AddressStats: Decodable {
                let chain_stats: TxoStats
                let mempool_stats: TxoStats
            }
            guard let stats = try? JSONDecoder().decode(AddressStats.self, from: data) else { return nil }
            let c = stats.chain_stats, m = stats.mempool_stats
            self.init(
                balanceSats: max(0, c.funded_txo_sum + m.funded_txo_sum - c.spent_txo_sum - m.spent_txo_sum),
                utxoCount: max(0, c.funded_txo_count + m.funded_txo_count - c.spent_txo_count - m.spent_txo_count)
            )
        }

        init(balanceSats: Int, utxoCount: Int) {
            self.balanceSats = balanceSats
            self.utxoCount = utxoCount
        }
    }
}
