import Foundation
import Combine
import SilentPaymentsKit
import Security

@MainActor
class SPScanService: ObservableObject {
    static let shared = SPScanService()

    @Published var discoveredUTXOs: [SPStoredUTXO] = []
    @Published var totalBalanceSats: UInt64 = 0
    @Published var isScanning: Bool = false
    @Published var lastError: String? = nil

    private var processedNotificationIds = Set<String>()
    private var wallet: SilentPaymentWallet?

    private init() {
        loadState()
    }

    // MARK: - Public

    /// Called by DMService when a gift wrap content matches SP notification schema.
    func handleNotification(
        _ notification: SilentPaymentNotification,
        from senderPubkey: String,
        at timestamp: Date,
        eventId: String
    ) {
        let notifKey = "\(notification.txid):\(notification.tweak)"
        guard !processedNotificationIds.contains(notifKey) else { return }

        processedNotificationIds.insert(notifKey)
        isScanning = true
        lastError = nil

        Task {
            defer { self.isScanning = false }

            do {
                let wallet = try getOrCreateWallet()

                let outputs = try await MempoolAPIService.fetchTaprootOutputs(txid: notification.txid)
                guard !outputs.isEmpty else {
                    saveState()
                    return
                }

                let taprootHexKeys = outputs.map { $0.xOnlyKeyHex }
                let foundOutputs = try wallet.scanWithNotification(
                    notification,
                    taprootOutputsHex: taprootHexKeys
                )

                guard !foundOutputs.isEmpty else {
                    saveState()
                    return
                }

                for spOutput in foundOutputs {
                    let xOnlyHex = spOutput.taprootXOnlyKey.map { String(format: "%02x", $0) }.joined()

                    guard let mempoolMatch = outputs.first(where: { $0.xOnlyKeyHex == xOnlyHex }) else {
                        continue
                    }

                    let utxoId = "\(notification.txid):\(mempoolMatch.vout)"
                    guard !discoveredUTXOs.contains(where: { $0.id == utxoId }) else { continue }

                    storeSpendKey(spOutput.spendPrivateKey, forUTXO: utxoId)

                    let utxo = SPStoredUTXO(
                        id: utxoId,
                        txid: notification.txid,
                        vout: mempoolMatch.vout,
                        taprootXOnlyKeyHex: xOnlyHex,
                        amountSats: mempoolMatch.amountSats,
                        discoveredAt: timestamp,
                        senderPubkey: senderPubkey,
                        label: spOutput.label,
                        blockhash: notification.blockhash,
                        isSwept: false,
                        sweepTxid: nil
                    )

                    discoveredUTXOs.append(utxo)
                }

                recalculateBalance()
                saveState()

            } catch {
                lastError = error.localizedDescription
                saveState()
            }
        }
    }

    /// Mark UTXOs as swept and persist the state.
    func markSwept(utxoIds: [String], sweepTxid: String) {
        for id in utxoIds {
            if let idx = discoveredUTXOs.firstIndex(where: { $0.id == id }) {
                discoveredUTXOs[idx].isSwept = true
                discoveredUTXOs[idx].sweepTxid = sweepTxid
            }
        }
        recalculateBalance()
        saveState()
    }

    /// Retrieve the spend private key for a given UTXO (from Keychain).
    func retrieveSpendKey(forUTXO id: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.haven.sp-utxo",
            kSecAttrAccount as String: id,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Private

    private func getOrCreateWallet() throws -> SilentPaymentWallet {
        if let w = wallet { return w }
        guard let hexKey = SilentPaymentService.getOwnerHexKey() else {
            throw SPScanError.noPrivateKey
        }
        let w = try SilentPaymentService.createWallet(hexPrivkey: hexKey)
        wallet = w
        return w
    }

    private func storeSpendKey(_ key: Data, forUTXO id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.haven.sp-utxo",
            kSecAttrAccount as String: id,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func recalculateBalance() {
        totalBalanceSats = discoveredUTXOs
            .filter { !$0.isSwept }
            .reduce(0) { $0 + $1.amountSats }
    }

    // MARK: - Persistence

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL()),
              let state = try? JSONDecoder().decode(SPScanState.self, from: data) else { return }
        processedNotificationIds = state.processedNotificationIds
        discoveredUTXOs = state.utxos
        recalculateBalance()
    }

    private func saveState() {
        let state = SPScanState(
            processedNotificationIds: processedNotificationIds,
            lastScanTimestamp: Int64(Date().timeIntervalSince1970),
            utxos: discoveredUTXOs
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let url = stateFileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
    }

    private func stateFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Haven", isDirectory: true)
            .appendingPathComponent("sp_scan_state.json")
    }

    enum SPScanError: Error, LocalizedError {
        case noPrivateKey

        var errorDescription: String? {
            switch self {
            case .noPrivateKey: return "Private key not available for SP scanning"
            }
        }
    }
}
