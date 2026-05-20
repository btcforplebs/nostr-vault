package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	btcec "github.com/btcsuite/btcd/btcec/v2"
	"github.com/btcsuite/btcd/btcec/v2/schnorr"
	"github.com/btcsuite/btcd/btcutil"
	"github.com/btcsuite/btcd/chaincfg"
	"github.com/btcsuite/btcd/chaincfg/chainhash"
	"github.com/btcsuite/btcd/txscript"
	"github.com/btcsuite/btcd/wire"
	secp "github.com/decred/dcrd/dcrec/secp256k1/v4"
)

const mempoolBase = "https://mempool.btcforplebs.com"
const mempoolFallback = "https://mempool.space"

// deriveP2TRAddress derives a Bitcoin Taproot (P2TR) address from a 32-byte
// hex-encoded x-only public key using BIP-341 key-path-only spending.
// The same secp256k1 keypair used for Nostr is valid for Bitcoin Taproot.
func deriveP2TRAddress(hexPubKey string) (string, error) {
	pubKeyBytes, err := hex.DecodeString(hexPubKey)
	if err != nil || len(pubKeyBytes) != 32 {
		return "", fmt.Errorf("invalid pubkey: expected 32 hex bytes, got %d", len(pubKeyBytes))
	}

	// Parse as compressed point with even y (BIP-340 / lift_x convention)
	compressed := make([]byte, 33)
	compressed[0] = 0x02
	copy(compressed[1:], pubKeyBytes)
	internalKey, err := secp.ParsePubKey(compressed)
	if err != nil {
		return "", fmt.Errorf("failed to parse pubkey: %w", err)
	}

	// BIP-341 TapTweak: t = SHA256(SHA256("TapTweak") || SHA256("TapTweak") || P)
	tweak := tapTweakHash(pubKeyBytes)

	// Compute Q = P + t·G via Jacobian point arithmetic
	var tweakScalar secp.ModNScalar
	tweakScalar.SetByteSlice(tweak)

	var tweakPoint, internalPoint, outputPoint secp.JacobianPoint
	secp.ScalarBaseMultNonConst(&tweakScalar, &tweakPoint)
	internalKey.AsJacobian(&internalPoint)
	secp.AddNonConst(&internalPoint, &tweakPoint, &outputPoint)
	outputPoint.ToAffine()

	// Witness program is the 32-byte x-coordinate of the output key
	xBytes := outputPoint.X.Bytes()
	return encodeBech32m("bc", 1, xBytes[:])
}

func tapTweakHash(pubKeyBytes []byte) []byte {
	tag := []byte("TapTweak")
	tagHash := sha256.Sum256(tag)
	h := sha256.New()
	h.Write(tagHash[:])
	h.Write(tagHash[:])
	h.Write(pubKeyBytes)
	return h.Sum(nil)
}

// deriveSpendingKey computes the BIP-341 key-path taproot spending private key
// from a Nostr nsec. The Nostr secp256k1 keypair is the internal key; the
// spending key is q = p + tapTweakHash(P) mod n, with BIP-340 parity corrections.
func deriveSpendingKey(nsecBytes []byte) (*btcec.PrivateKey, error) {
	if len(nsecBytes) != 32 {
		return nil, fmt.Errorf("nsec must be 32 bytes")
	}

	privKey, pubKey := btcec.PrivKeyFromBytes(nsecBytes)

	// BIP-340 lift_x: the internal key is always treated as even-y.
	// If the actual pubkey has odd y, negate p so p·G has even y.
	var p secp.ModNScalar
	p.Set(&privKey.Key)
	if pubKey.SerializeCompressed()[0] == 0x03 {
		p.Negate()
	}

	// x-only pubkey bytes (32 bytes, no parity prefix)
	xOnly := pubKey.SerializeCompressed()[1:]

	// Compute tweak scalar t = tapTweakHash(P)
	tweak := tapTweakHash(xOnly)
	var t secp.ModNScalar
	t.SetByteSlice(tweak)

	// q = p + t mod n
	var q secp.ModNScalar
	q.Set(&p)
	q.Add(&t)

	// Materialise as a private key and check output key parity.
	// BIP-341: if Q = q·G has odd y, the signing scalar is n - q.
	var qBytes [32]byte
	q.PutBytes(&qBytes)
	finalKey, finalPub := btcec.PrivKeyFromBytes(qBytes[:])
	if finalPub.SerializeCompressed()[0] == 0x03 {
		q.Negate()
		q.PutBytes(&qBytes)
		finalKey, _ = btcec.PrivKeyFromBytes(qBytes[:])
	}
	return finalKey, nil
}

// --- UTXO fetching ---

type utxo struct {
	Txid   string `json:"txid"`
	Vout   uint32 `json:"vout"`
	Value  int64  `json:"value"`
	Status struct {
		Confirmed bool `json:"confirmed"`
	} `json:"status"`
}

func fetchUTXOs(address string) ([]utxo, error) {
	utxos, err := fetchUTXOsFrom(mempoolBase, address)
	if err != nil {
		// Primary server may not support this endpoint; fall back to mempool.space.
		return fetchUTXOsFrom(mempoolFallback, address)
	}
	return utxos, nil
}

func fetchUTXOsFrom(base, address string) ([]utxo, error) {
	resp, err := http.Get(base + "/api/address/" + address + "/utxo")
	if err != nil {
		return nil, fmt.Errorf("fetch UTXOs: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return nil, fmt.Errorf("fetch UTXOs: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var utxos []utxo
	if err := json.NewDecoder(resp.Body).Decode(&utxos); err != nil {
		return nil, fmt.Errorf("decode UTXOs: %w", err)
	}
	return utxos, nil
}

// FeeEstimates holds sat/vB recommendations from the mempool fee API.
type FeeEstimates struct {
	FastestFee  int `json:"fastestFee"`
	HalfHourFee int `json:"halfHourFee"`
	HourFee     int `json:"hourFee"`
	EconomyFee  int `json:"economyFee"`
}

func fetchFeeEstimates() (FeeEstimates, error) {
	resp, err := http.Get(mempoolBase + "/api/v1/fees/recommended")
	if err != nil {
		return FeeEstimates{}, fmt.Errorf("fetch fees: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return FeeEstimates{}, fmt.Errorf("fetch fees: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var fees FeeEstimates
	if err := json.NewDecoder(resp.Body).Decode(&fees); err != nil {
		return FeeEstimates{}, fmt.Errorf("decode fees: %w", err)
	}
	return fees, nil
}

// --- Transaction building ---

// simplePrevOutFetcher is a map-backed PrevOutputFetcher for multi-input txns.
type simplePrevOutFetcher struct {
	prevOuts map[wire.OutPoint]*wire.TxOut
}

func newSimplePrevOutFetcher() *simplePrevOutFetcher {
	return &simplePrevOutFetcher{prevOuts: make(map[wire.OutPoint]*wire.TxOut)}
}

func (f *simplePrevOutFetcher) add(op wire.OutPoint, txOut *wire.TxOut) {
	f.prevOuts[op] = txOut
}

func (f *simplePrevOutFetcher) FetchPrevOutput(op wire.OutPoint) *wire.TxOut {
	if out, ok := f.prevOuts[op]; ok {
		return out
	}
	return &wire.TxOut{}
}

// estimateSweepVsize returns the virtual size in vBytes for a taproot key-path
// sweep with the given number of P2TR inputs and one P2TR output.
//
//   - P2TR key-path input (non-witness): 41 vB (outpoint 36 + scriptLen 1 + seq 4)
//   - P2TR key-path witness per input:   66 bytes (item-count 1 + sig-len 1 + sig 64)
//   - P2TR output:                       43 vB (value 8 + scriptLen 1 + script 34)
//   - Tx overhead:                       10 vB (version 4 + vin-varint 1 + vout-varint 1 + locktime 4)
//   - Segwit flag bytes:                  2 bytes (witness discount)
func estimateSweepVsize(numInputs int) int64 {
	nonWitness := int64(10 + 41*numInputs + 43)
	witness := int64(2 + 66*numInputs)
	weight := nonWitness*4 + witness
	return (weight + 3) / 4
}

// SweepResult is the return value of buildAndBroadcastSweep.
type SweepResult struct {
	Txid   string `json:"txid"`
	Amount int64  `json:"amount"`
	Fee    int64  `json:"fee"`
}

// buildAndBroadcastSweep sweeps all UTXOs from the Nostr-derived taproot address
// to destAddr, paying feeRateSatsPerVB sat/vB. Returns the txid on success.
func buildAndBroadcastSweep(nsecHex, destAddr string, feeRateSatsPerVB int64) (*SweepResult, error) {
	nsecBytes, err := hex.DecodeString(nsecHex)
	if err != nil || len(nsecBytes) != 32 {
		return nil, fmt.Errorf("invalid nsec")
	}

	// Derive source address from nsec pubkey
	_, pubKey := btcec.PrivKeyFromBytes(nsecBytes)
	xOnlyHex := hex.EncodeToString(pubKey.SerializeCompressed()[1:])
	sourceAddr, err := deriveP2TRAddress(xOnlyHex)
	if err != nil {
		return nil, fmt.Errorf("derive source address: %w", err)
	}

	// Fetch all UTXOs (confirmed + unconfirmed)
	utxos, err := fetchUTXOs(sourceAddr)
	if err != nil {
		return nil, err
	}
	if len(utxos) == 0 {
		return nil, fmt.Errorf("no UTXOs found at %s", sourceAddr)
	}

	var total int64
	for _, u := range utxos {
		total += u.Value
	}

	fee := estimateSweepVsize(len(utxos)) * feeRateSatsPerVB
	sendAmount := total - fee
	if sendAmount < 546 {
		return nil, fmt.Errorf("insufficient funds: %d sats, fee %d sats", total, fee)
	}

	// Parse destination address
	destAddress, err := btcutil.DecodeAddress(destAddr, &chaincfg.MainNetParams)
	if err != nil {
		return nil, fmt.Errorf("invalid destination address: %w", err)
	}
	destScript, err := txscript.PayToAddrScript(destAddress)
	if err != nil {
		return nil, fmt.Errorf("build dest script: %w", err)
	}

	// Parse source address for the scriptPubKey (needed by sighash)
	srcAddress, err := btcutil.DecodeAddress(sourceAddr, &chaincfg.MainNetParams)
	if err != nil {
		return nil, fmt.Errorf("parse source address: %w", err)
	}
	srcScript, err := txscript.PayToAddrScript(srcAddress)
	if err != nil {
		return nil, fmt.Errorf("build source script: %w", err)
	}

	// Build transaction
	tx := wire.NewMsgTx(2)
	fetcher := newSimplePrevOutFetcher()
	for _, u := range utxos {
		hash, err := chainhash.NewHashFromStr(u.Txid)
		if err != nil {
			return nil, fmt.Errorf("invalid txid %s: %w", u.Txid, err)
		}
		op := wire.OutPoint{Hash: *hash, Index: u.Vout}
		tx.AddTxIn(&wire.TxIn{
			PreviousOutPoint: op,
			Sequence:         wire.MaxTxInSequenceNum - 2, // RBF
		})
		fetcher.add(op, &wire.TxOut{Value: u.Value, PkScript: srcScript})
	}
	tx.AddTxOut(&wire.TxOut{Value: sendAmount, PkScript: destScript})

	// Derive BIP-341 spending key and sign each input
	spendingKey, err := deriveSpendingKey(nsecBytes)
	if err != nil {
		return nil, fmt.Errorf("derive spending key: %w", err)
	}

	sigHashes := txscript.NewTxSigHashes(tx, fetcher)
	for i := range tx.TxIn {
		sigHash, err := txscript.CalcTaprootSignatureHash(sigHashes, txscript.SigHashDefault, tx, i, fetcher)
		if err != nil {
			return nil, fmt.Errorf("sighash input %d: %w", i, err)
		}
		sig, err := schnorr.Sign(spendingKey, sigHash)
		if err != nil {
			return nil, fmt.Errorf("sign input %d: %w", i, err)
		}
		tx.TxIn[i].Witness = wire.TxWitness{sig.Serialize()}
	}

	// Serialize and broadcast
	var buf bytes.Buffer
	if err := tx.Serialize(&buf); err != nil {
		return nil, fmt.Errorf("serialize tx: %w", err)
	}
	rawHex := hex.EncodeToString(buf.Bytes())

	txid, err := broadcastTx(rawHex)
	if err != nil {
		return nil, err
	}

	return &SweepResult{Txid: txid, Amount: sendAmount, Fee: fee}, nil
}

func broadcastTx(rawHex string) (string, error) {
	txid, err := broadcastTxTo(mempoolBase+"/api/tx/push", rawHex)
	if err != nil {
		// Fall back to mempool.space if the primary rejects.
		return broadcastTxTo(mempoolFallback+"/api/tx", rawHex)
	}
	return txid, nil
}

func broadcastTxTo(url, rawHex string) (string, error) {
	resp, err := http.Post(url, "text/plain", strings.NewReader(rawHex))
	if err != nil {
		return "", fmt.Errorf("broadcast: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("broadcast rejected: %s", strings.TrimSpace(string(body)))
	}
	return strings.TrimSpace(string(body)), nil
}

// --- bech32m encoding (BIP-350) ---

const bech32Charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
const bech32mConst = uint32(0x2bc830a3)

func bech32Polymod(values []byte) uint32 {
	gen := []uint32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := uint32(1)
	for _, v := range values {
		b := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ uint32(v)
		for i := 0; i < 5; i++ {
			if (b>>uint(i))&1 == 1 {
				chk ^= gen[i]
			}
		}
	}
	return chk
}

func bech32HRPExpand(hrp string) []byte {
	ret := make([]byte, 0, len(hrp)*2+1)
	for _, c := range hrp {
		ret = append(ret, byte(c)>>5)
	}
	ret = append(ret, 0)
	for _, c := range hrp {
		ret = append(ret, byte(c)&31)
	}
	return ret
}

func bech32mChecksum(hrp string, data []byte) []byte {
	values := append(bech32HRPExpand(hrp), data...)
	polymod := bech32Polymod(append(values, 0, 0, 0, 0, 0, 0)) ^ bech32mConst
	ret := make([]byte, 6)
	for i := range ret {
		ret[i] = byte(polymod>>(5*(5-i))) & 31
	}
	return ret
}

func convertBits8to5(data []byte) []byte {
	acc, bits := 0, 0
	var ret []byte
	for _, v := range data {
		acc = (acc << 8) | int(v)
		bits += 8
		for bits >= 5 {
			bits -= 5
			ret = append(ret, byte((acc>>bits)&31))
		}
	}
	if bits > 0 {
		ret = append(ret, byte((acc<<(5-bits))&31))
	}
	return ret
}

func encodeBech32m(hrp string, witnessVersion byte, witnessProgram []byte) (string, error) {
	payload := append([]byte{witnessVersion}, convertBits8to5(witnessProgram)...)
	checksum := bech32mChecksum(hrp, payload)
	combined := append(payload, checksum...)
	var sb strings.Builder
	sb.WriteString(hrp)
	sb.WriteByte('1')
	for _, b := range combined {
		sb.WriteByte(bech32Charset[b])
	}
	return sb.String(), nil
}
