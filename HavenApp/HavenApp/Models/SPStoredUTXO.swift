import Foundation

struct SPStoredUTXO: Codable, Identifiable {
    /// Unique identifier: "txid:vout"
    let id: String
    /// Transaction ID (64-char hex)
    let txid: String
    /// Output index in the transaction
    let vout: UInt32
    /// 32-byte x-only Taproot output key (hex)
    let taprootXOnlyKeyHex: String
    /// Value of this output in satoshis
    let amountSats: UInt64
    /// When the notification was received
    let discoveredAt: Date
    /// Nostr pubkey of the sender who sent the notification
    let senderPubkey: String
    /// Optional BIP-352 label index
    let label: UInt32?
    /// Block hash from the notification (if confirmed)
    let blockhash: String?
    /// Whether this UTXO has been swept
    var isSwept: Bool
    /// Txid of the sweep transaction (if swept)
    var sweepTxid: String?
}

struct SPScanState: Codable {
    var processedNotificationIds: Set<String>
    var lastScanTimestamp: Int64
    var utxos: [SPStoredUTXO]
}
