# Bitcoin Sweep — Implementation Plan

Spend from the taproot address that every profile derives from their Nostr pubkey.
Address derivation already exists in `haven-go/bitcoin.go` (BIP-341 key-path-only, no script tree).

---

## What you already have ✅

| Piece | Where |
|---|---|
| Taproot address derivation (`DeriveTaprootAddressC`) | `haven-go/bitcoin.go` |
| Mempool API wired up (balance fetch) | `haven-go/bitcoin.go`, `ProfileView.swift` |
| `btcec/v2` (v2.3.6) — secp256k1 EC ops + **Schnorr signing** | `go.mod` (indirect) |
| `btcutil` (v1.1.5) — address parsing | `go.mod` (indirect) |
| `decred/dcrd/dcrec/secp256k1/v4` — scalar arithmetic for key tweaking | `go.mod` (indirect) |
| cgo export pattern (`SignEventC`, `DeriveTaprootAddressC`) | `haven-go/cshared.go` |
| nsec accessible in Swift | `NostrService.swift` |

---

## What's missing ❌

### 1. `github.com/btcsuite/btcd` (direct dep, not yet in go.mod)
Needed for:
- `wire.MsgTx` — transaction struct + serialization
- `txscript.CalcTaprootSignatureHash` — BIP-341 sighash (very fiddly to hand-roll correctly)
- `txscript.PayToTaprootScript` — builds the `OP_1 <32-byte-key>` output script

Without this you'd have to hand-implement BIP-341 sighash and raw tx serialization. Doable, but high foot-gun risk since a single byte error burns sats. Pull in btcd.

### 2. Go: `deriveSpendingKey` in `bitcoin.go`
Computes `q = (p + tapTweakHash(P)) mod n`, handling BIP-340 y-parity negation.
The secp256k1 and btcec libs already have all the scalar ops needed.

### 3. Go: `fetchUTXOs` in `bitcoin.go`
`GET mempool.btcforplebs.com/api/address/{addr}/utxo`  
Returns JSON array: `[{ txid, vout, value, status: { confirmed } }]`

### 4. Go: `buildAndSignTx` in `bitcoin.go`
- Select UTXOs (confirmed first, cover amount + fee)
- Compute fee: `feeRate (sat/vB) × txVsize`; P2TR key-path input = 57.5 vB each, P2TR output = 43 vB, overhead = 10.5 vB
- Build `wire.MsgTx`, compute taproot sighash, Schnorr-sign with `btcec/v2/schnorr`
- Serialize to hex

### 5. Go: `broadcastTx` in `bitcoin.go`
`POST mempool.btcforplebs.com/api/tx` with raw hex body.  
Returns txid on success.

### 6. Go: `SweepToAddressC` exported function in `cshared.go`
```go
//export SweepToAddressC
func SweepToAddressC(nsecHex *C.char, destAddr *C.char, feeRateSatsPerVB C.int) *C.char
// Returns JSON: { "txid": "...", "fee": 1234 } or { "error": "..." }
```

### 7. Swift: Sweep UI (new sheet off ProfileView or SettingsView)
- "Sweep to address" button — only shown on own profile AND balance > 0
- Destination address field
- Fee rate picker (economy / normal / priority — fetched from mempool fee estimates API)
- Preview: shows amount, fee, net received
- Confirm → calls `SweepToAddressC` → shows txid with mempool.space link

---

## Implementation Order

1. **`go get github.com/btcsuite/btcd@latest`** — promote to direct dep
2. **`deriveSpendingKey`** — pure math, easy to unit test
3. **`fetchUTXOs`** — simple HTTP, verify against mempool.space manually
4. **`buildAndSignTx`** — hardest step; write a test that signs a known UTXO against testnet/signet first
5. **`broadcastTx`** + **`SweepToAddressC`** — wire everything together behind the C export
6. **Swift sweep sheet** — only after Go layer is confirmed working

---

## Risk / Notes

- The taproot spending key derivation requires careful BIP-340 y-parity handling. The `btcec/v2` `PrivKeyFromBytes` function returns a normalized key (handles this). Use `btcec` for key work, not the raw decred secp256k1 scalars.
- Fee estimation: call `mempool.btcforplebs.com/api/v1/fees/recommended` → `{ fastestFee, halfHourFee, hourFee, economyFee }`.
- Dust threshold for P2TR outputs is 330 sats — don't create a change output below that, just absorb it into the fee.
- This only covers **own-profile sweep**. Other profiles' addresses are receive-only (no key access).
