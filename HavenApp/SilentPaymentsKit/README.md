# SilentPaymentsKit

A native Swift package for iOS/macOS implementing [BIP-352 Silent Payments](https://bips.dev/352/) 
with support for multiple key sources and [Nostr NIP-17 payment notifications](https://delvingbitcoin.org/t/silent-payments-notifications-via-nostr/2203).

---

## Architecture

```
SilentPaymentsKit
├── Core/
│   ├── SilentPaymentTypes.swift      — All types: address, keypair, input, output, notification
│   ├── CryptoHelpers.swift           — Tagged hashes, secp256k1 point math
│   ├── Bech32m.swift                 — sp1... address codec
│   ├── SilentPaymentSender.swift     — Output key derivation (sender side)
│   └── SilentPaymentReceiver.swift   — Output scanning (receiver side)
│
├── Adapters/
│   ├── BIP32Adapter.swift            — BIP-32 HD wallet → BIP-352 keys (m/352'/coin'/acct'/…)
│   └── NostrSilentWalletAdapter.swift — Nostr nsec → BIP-352 keys (NSW derivation)
│
├── Nostr/
│   └── NostrNotificationService.swift — NIP-17 gift-wrap DM send/receive
│
└── SilentPaymentWallet.swift         — High-level facade for app developers
```

---

## Key Sources

All three produce a standard `sp1...` address. Any sender wallet (Cake Wallet, Blue Wallet, etc.) 
pays all of them identically — the difference is only in how the *receiver* derives their keys.

| Source | How | Best for |
|--------|-----|----------|
| `BIP32` | `m/352'/0'/0'/0'/0` scan, `m/352'/0'/0'/1'/0` spend | Standard Bitcoin wallet users |
| `Nostr` | `P + H_tag("nostr-sp/scan", P)·G` etc. | Nostr identity–linked payments (NSW) |
| `RawKeys` | Bring your own secp256k1 keys | Advanced integrations |

---

## Usage

### Receiving (generate your address)

```swift
import SilentPaymentsKit

// From a Nostr nsec
let nsecBytes: Data = ... // 32-byte private key
let wallet = try SilentPaymentWallet(source: .nostr(nsec: nsecBytes))
print(wallet.address)  // sp1qq...

// From a BIP-32 HD seed
let wallet = try SilentPaymentWallet(
    source: .bip32(masterKey: masterKeyBytes, chainCode: chainCodeBytes, network: .mainnet, account: 0)
)

// Shareable payment URI (BIP-321)
let uri = wallet.paymentURI(npub: "npub1...", relays: ["wss://relay.damus.io"])
// → bitcoin:?sp1qq...=&npub=npub1...&relays=wss://relay.damus.io
```

### Sending (derive the output key)

```swift
let senderWallet = try SilentPaymentWallet(source: .nostr(nsec: mySec))

let inputs = [
    SilentPaymentInput(
        outpoint: outpointData,   // 36 bytes: txid-LE(32) || vout-LE(4)
        privateKey: utxoPrivKey,  // 32-byte private key for that UTXO
        inputType: .p2wpkh
    )
]

// Get the P2TR output key for the recipient
let outputKeys = try senderWallet.deriveOutputKey(to: "sp1qq...", inputs: inputs)
let xOnlyKey   = outputKeys[0].dropFirst()  // 32-byte x-only for P2TR script

// Build notification for the receiver
let tweakHex = try senderWallet.computeNotificationTweak(inputs: inputs)
let notification = SilentPaymentNotification(txid: confirmedTxid, tweak: tweakHex)
```

### Nostr notification: sender publishes

```swift
let nostrService = NostrNotificationService(relays: [
    URL(string: "wss://relay.damus.io")!,
    URL(string: "wss://nos.lol")!
])

try await nostrService.sendNotification(
    notification,
    senderNsec: mySec,
    recipientNpub: recipientCompressedPubKey
)
```

### Nostr notification: receiver scans

```swift
try await nostrService.subscribeToNotifications(
    recipientNsec: myNsec,
    since: lastScanTimestamp
) { notification in
    let outputs = try wallet.scanWithNotification(notification, taprootOutputsHex: txOutputs)
    for output in outputs {
        print("Found output: \(output.taprootXOnlyKey.hexString)")
        // output.spendPrivateKey — use to sign a spending transaction
    }
}
```

### Anti-spoofing: verify NSW address from npub

```swift
// Sender derives the expected address from identity — no need to trust a shared address.
let isLegit = try SilentPaymentWallet.verifyNSWAddress("sp1qq...", npub: "npub1...")
```

### Labels (track payment sources)

```swift
let donationAddress = try wallet.createLabel("donations")  // sp1qq... (different spend key)
let exchangeAddress = try wallet.createLabel("kraken")
// Both share the same scan key — one scan covers all labeled addresses
```

---

## Dependencies

- [`GigaBitcoin/secp256k1.swift`](https://github.com/GigaBitcoin/secp256k1.swift) — secp256k1 key math (ECDH, Schnorr, point arithmetic)
- [`nostr-sdk/nostr-sdk-ios`](https://github.com/nostr-sdk/nostr-sdk-ios) — Nostr relay/event handling

Both are Swift packages — no C bridging headers, no Cocoapods.

---

## BIP-352 Compliance Notes

- ✅ Input hash: `H_BIP0352/Inputs(outpointL || Ainput)`  
- ✅ Shared secret: `H_BIP0352/SharedSecret(ecdh_shared_secret || ser32(k))`  
- ✅ Labels: `H_BIP0352/Label(bscan || ser32(m))`, m=0 reserved for change  
- ✅ P2TR input negation (odd-Y keys negated before summing)  
- ✅ Scan/spend key separation (bscan online, bspend can stay in Secure Enclave)  
- ✅ Multiple outputs per recipient (k=0,1,2…)  
- ✅ Lexicographically smallest outpoint for input hash  

## NSW Compliance Notes

- ✅ Deterministic derivation: `ScanPub = P + H_tag("nostr-sp/scan", P)·G`  
- ✅ Public address verifiable from npub alone (anti-spoofing)  
- ✅ Plausible deniability (anyone can derive the address, not proof of intent)  
- ✅ Compatible with all existing BIP-352 sender wallets  

---

## Security Notes

1. **Never reuse the nsec** for both Nostr signing and direct Bitcoin spending. NSW keeps them separated by the deterministic tweak.
2. **Always sweep NSW outputs** to a fresh address — don't spend directly from the NSW wallet.
3. **NIP-44 implementation** in `NostrNotificationService` is functional but not fully audited. For production, link a dedicated NIP-44 library.
4. **Spam resilience**: If you receive a forged notification tweak, the scan will simply find no outputs. Bob can always fall back to full chain scanning.
