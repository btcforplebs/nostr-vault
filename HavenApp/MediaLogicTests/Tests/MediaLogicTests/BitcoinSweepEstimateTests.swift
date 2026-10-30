import XCTest
@testable import MediaLogic

/// The sweep spends every unspent output, so a fee priced for one input
/// underpays as soon as the address holds two. These sizes must match
/// estimateSweepVsize in haven-go/bitcoin.go, which builds the real tx.
final class BitcoinSweepEstimateTests: XCTestCase {

    func testVsizeMatchesGoForOneTwoAndManyInputs() {
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: 1), 111)
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: 2), 169)
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: 3), 226)
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: 10), 629)
    }

    func testZeroOrNegativeCountPricesOneInput() {
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: 0), 111)
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: -4), 111)
    }

    func testHugeCountIsCappedInsteadOfTrapping() {
        let capped = BitcoinSweepEstimate.vsize(utxoCount: BitcoinSweepEstimate.maxUTXOCount)
        XCTAssertEqual(BitcoinSweepEstimate.vsize(utxoCount: Int.max), capped)
        XCTAssertEqual(BitcoinSweepEstimate.fee(utxoCount: Int.max, feeRate: 1_000), capped * 1_000)
    }

    func testFeeScalesWithInputs() {
        XCTAssertEqual(BitcoinSweepEstimate.fee(utxoCount: 1, feeRate: 5), 555)
        XCTAssertEqual(BitcoinSweepEstimate.fee(utxoCount: 2, feeRate: 5), 845)
    }

    func testParsesCountAndBalanceAcrossChainAndMempool() throws {
        let json = """
        {"address":"bc1p","chain_stats":{"funded_txo_count":4,"funded_txo_sum":300000,"spent_txo_count":1,"spent_txo_sum":100000,"tx_count":5},
         "mempool_stats":{"funded_txo_count":1,"funded_txo_sum":5000,"spent_txo_count":1,"spent_txo_sum":50000,"tx_count":2}}
        """
        let funds = try XCTUnwrap(BitcoinSweepEstimate.AddressFunds(mempoolJSON: Data(json.utf8)))
        XCTAssertEqual(funds, .init(balanceSats: 155_000, utxoCount: 3))
    }

    func testBalanceOverInt32Max() throws {
        // 30 BTC: over 2,147,483,647 sats (about 21.47 BTC).
        let json = """
        {"chain_stats":{"funded_txo_count":2,"funded_txo_sum":3000000000,"spent_txo_count":0,"spent_txo_sum":0},
         "mempool_stats":{"funded_txo_count":0,"funded_txo_sum":0,"spent_txo_count":0,"spent_txo_sum":0}}
        """
        let funds = try XCTUnwrap(BitcoinSweepEstimate.AddressFunds(mempoolJSON: Data(json.utf8)))
        XCTAssertEqual(funds.balanceSats, 3_000_000_000)
        XCTAssertEqual(funds.utxoCount, 2)
    }

    func testRejectsReplyWhoseSumsOverflow() {
        let json = """
        {"chain_stats":{"funded_txo_count":9223372036854775807,"funded_txo_sum":1,"spent_txo_count":0,"spent_txo_sum":0},
         "mempool_stats":{"funded_txo_count":9223372036854775807,"funded_txo_sum":0,"spent_txo_count":0,"spent_txo_sum":0}}
        """
        XCTAssertNil(BitcoinSweepEstimate.AddressFunds(mempoolJSON: Data(json.utf8)))
    }

    func testRejectsNonAddressReply() {
        XCTAssertNil(BitcoinSweepEstimate.AddressFunds(mempoolJSON: Data("Invalid Bitcoin address".utf8)))
    }
}
