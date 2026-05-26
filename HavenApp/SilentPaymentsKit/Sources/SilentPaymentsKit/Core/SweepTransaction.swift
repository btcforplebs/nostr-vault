// Sources/SilentPaymentsKit/Core/SweepTransaction.swift
//
// NSW Sweep — builds a signed Bitcoin transaction that spends one or more
// Silent Payment outputs (P2TR key-path) to a destination address.
//
// Flow:
//   1. You have SilentPaymentOutput(s) from SilentPaymentReceiver.scan*
//   2. Call SweepTransaction.build(...) → returns raw signed tx bytes
//   3. Broadcast via your preferred Bitcoin node / API
//
// Signing uses BIP-340 Schnorr key-path spending (no script, no tapscript).
// The spend private key for each output is already computed by the receiver:
//   spend_priv = bspend + t_k  (or + label_scalar for labeled outputs)

import Foundation
import CryptoKit

// MARK: - Sweep Input / Output types

/// A confirmed Silent Payment output ready to be spent.
public struct SweepInput {
    /// The found output from SilentPaymentReceiver
    public let output: SilentPaymentOutput
    /// The UTXO value in satoshis
    public let amountSats: UInt64
    /// The txid of the transaction containing this output (32 bytes, internal byte order)
    public let txid: Data
    /// The output index (vout) in that transaction
    public let vout: UInt32
    /// Sequence number (default: 0xFFFFFFFD for RBF)
    public let sequence: UInt32

    public init(
        output: SilentPaymentOutput,
        amountSats: UInt64,
        txid: Data,
        vout: UInt32,
        sequence: UInt32 = 0xFFFFFFFD
    ) {
        self.output = output
        self.amountSats = amountSats
        self.txid = txid
        self.vout = vout
        self.sequence = sequence
    }
}

/// A sweep destination address and amount.
public struct SweepOutput {
    public let scriptPubKey: Data   // 34 bytes for P2TR, 22 for P2WPKH, etc.
    public let amountSats: UInt64

    public init(scriptPubKey: Data, amountSats: UInt64) {
        self.scriptPubKey = scriptPubKey
        self.amountSats = amountSats
    }

    /// Convenience: initialise from a bech32/bech32m address string.
    public init(address: String, amountSats: UInt64) throws {
        self.scriptPubKey = try AddressDecoder.toScriptPubKey(address)
        self.amountSats   = amountSats
    }
}

// MARK: - Fee estimation

public struct FeeEstimate {
    /// Satoshis per virtual byte
    public let satsPerVbyte: UInt64

    public init(satsPerVbyte: UInt64) {
        self.satsPerVbyte = satsPerVbyte
    }

    /// Estimate fee for a sweep: inputs all P2TR key-path, one P2TR output + optional change.
    /// vBytes = 10.5 (overhead) + 57.5 × nInputs + 43 × nOutputs  (rounded up)
    public func estimatedFee(inputCount: Int, outputCount: Int) -> UInt64 {
        // Weight units: base = 4×, witness = 1×
        // Tx overhead:  version(4) + segwit marker(2) + locktime(4) = 10 bytes base → 40 WU + 2 segwit = 42 WU
        // Each P2TR key-path input:
        //   non-witness: outpoint(36) + scriptLen(1) + seq(4) = 41 bytes → 164 WU
        //   witness: stack items(1) + sig len(1) + sig(64) = 66 bytes → 66 WU  → total 230 WU per input
        // Each P2TR output: value(8) + scriptLen(1) + script(34) = 43 bytes → 172 WU
        let weight = UInt64(42)
            + UInt64(inputCount)  * 230
            + UInt64(outputCount) * 172
        let vbytes = (weight + 3) / 4   // ceil
        return vbytes * satsPerVbyte
    }
}

// MARK: - Sweep Transaction Builder

public struct SweepTransaction {

    public struct Result {
        /// Raw signed transaction bytes, ready to broadcast.
        public let rawTx: Data
        /// Transaction ID (SHA256d of rawTx, reversed for display).
        public let txid: String
        /// Total fee paid in satoshis.
        public let feeSats: UInt64
        /// Number of inputs swept.
        public let inputCount: Int
    }

    // MARK: - Build + sign a sweep transaction

    /// Build and sign a transaction that sweeps all `inputs` to `destination`.
    ///
    /// - Parameters:
    ///   - inputs:       Silent Payment outputs to sweep (must be confirmed UTXOs).
    ///   - destination:  Where to send the funds (bech32/bech32m address or scriptPubKey).
    ///   - feeRate:      Fee rate in sats/vbyte.
    ///   - changeAddress: Optional change address. If nil, all leftover goes to fee.
    ///                   Pass your own fresh address to recover dust.
    ///   - dustLimit:    Outputs below this (default 546 sats) are dropped as dust.
    /// - Returns: Signed raw transaction bytes + txid.
    public static func build(
        inputs: [SweepInput],
        destination: SweepOutput,
        feeRate: FeeEstimate,
        changeAddress: String? = nil,
        dustLimit: UInt64 = 546
    ) throws -> Result {
        guard !inputs.isEmpty else {
            throw SweepError.noInputs
        }

        // ── Compute amounts ──────────────────────────────────────────────────
        let totalIn  = inputs.reduce(0) { $0 + $1.amountSats }
        let outputCount = changeAddress != nil ? 2 : 1
        let fee      = feeRate.estimatedFee(inputCount: inputs.count, outputCount: outputCount)

        guard totalIn >= destination.amountSats + fee else {
            throw SweepError.insufficientFunds(
                available: totalIn,
                required: destination.amountSats + fee
            )
        }

        // ── Outputs ──────────────────────────────────────────────────────────
        var outputs = [SweepOutput]()
        outputs.append(destination)

        if let changeAddr = changeAddress {
            let changeSats = totalIn - destination.amountSats - fee
            if changeSats >= dustLimit {
                let changeScript = try AddressDecoder.toScriptPubKey(changeAddr)
                outputs.append(SweepOutput(scriptPubKey: changeScript, amountSats: changeSats))
            }
        }

        let actualFee = totalIn - outputs.reduce(0) { $0 + $1.amountSats }

        // ── Build unsigned transaction ────────────────────────────────────────
        let unsignedTx = buildUnsignedTx(inputs: inputs, outputs: outputs)

        // ── Sign each input (BIP-340 Schnorr, BIP-341 key-path) ──────────────
        let signedTx = try signTx(unsignedTx: unsignedTx, inputs: inputs, outputs: outputs)

        // ── Compute txid (SHA256d, reversed) ─────────────────────────────────
        let hash1 = Data(SHA256.hash(data: signedTx))
        let hash2 = Data(SHA256.hash(data: hash1))
        let txid  = Data(hash2.reversed()).hexString

        return Result(
            rawTx:      signedTx,
            txid:       txid,
            feeSats:    actualFee,
            inputCount: inputs.count
        )
    }

    // MARK: - Unsigned transaction serialisation

    private static func buildUnsignedTx(inputs: [SweepInput], outputs: [SweepOutput]) -> UnsignedTx {
        UnsignedTx(inputs: inputs, outputs: outputs)
    }

    // MARK: - BIP-341 / BIP-342 Schnorr signing

    private static func signTx(
        unsignedTx: UnsignedTx,
        inputs: [SweepInput],
        outputs: [SweepOutput]
    ) throws -> Data {

        // Precompute the SHA256 hashes needed for the sighash (BIP-341 §Common signature message)
        let hashPrevouts  = sha256(inputs.flatMap { serializeOutpoint($0) })
        let hashAmounts   = sha256(inputs.flatMap { serializeUInt64LE($0.amountSats) })
        let hashScripts   = sha256(inputs.flatMap { serializeScript(p2trScript(from: $0.output.taprootXOnlyKey)) })
        let hashSequences = sha256(inputs.flatMap { serializeUInt32LE($0.sequence) })
        let hashOutputs   = sha256(outputs.flatMap { serializeOutput($0) })

        var witnesses = [[Data]]()

        for (i, input) in inputs.enumerated() {
            // BIP-341 sighash (SIGHASH_DEFAULT = 0x00, key-path spend)
            let sighash = try bip341Sighash(
                inputIndex:    UInt32(i),
                inputs:        inputs,
                outputs:       outputs,
                hashPrevouts:  hashPrevouts,
                hashAmounts:   hashAmounts,
                hashScripts:   hashScripts,
                hashSequences: hashSequences,
                hashOutputs:   hashOutputs
            )

            // Schnorr sign with the spend key for this output
            // BIP-341 key-path: the internal key is already the tweaked key stored in taprootXOnlyKey.
            // For NSW outputs, spendPrivateKey already encodes bspend + t_k (+ label if labeled).
            // We must ensure the key's Y is even (negate if odd) per BIP-340.
            var spendPriv = input.output.spendPrivateKey
            let spendPub  = try Secp256k1.publicKey(from: spendPriv)
            if Secp256k1.hasOddY(spendPub) {
                spendPriv = try Secp256k1.negatePrivKey(spendPriv)
            }

            let sig = try Secp256k1.schnorrSign(message: sighash, privateKey: spendPriv)
            // SIGHASH_DEFAULT: append nothing (64-byte sig only, no hash type byte)
            witnesses.append([sig])
        }

        return serialize(inputs: inputs, outputs: outputs, witnesses: witnesses)
    }

    // MARK: - BIP-341 sighash

    private static func bip341Sighash(
        inputIndex:    UInt32,
        inputs:        [SweepInput],
        outputs:       [SweepOutput],
        hashPrevouts:  Data,
        hashAmounts:   Data,
        hashScripts:   Data,
        hashSequences: Data,
        hashOutputs:   Data
    ) throws -> Data {
        // BIP-341 signature message (epoch 0):
        //   hash_TapSighash(0x00 || sigMsg)
        // sigMsg components:
        //   nVersion(4) + nLockTime(4) + sha_prevouts(32) + sha_amounts(32) +
        //   sha_scriptpubkeys(32) + sha_sequences(32) + sha_outputs(32) +
        //   spend_type(1) + outpoint(36) + amount(8) + scriptPubKey(var) + nSequence(4)

        let input  = inputs[Int(inputIndex)]
        let script = p2trScript(from: input.output.taprootXOnlyKey)

        var msg = Data()
        msg.append(contentsOf: [0x00])                        // epoch
        msg.append(contentsOf: serializeUInt32LE(2))           // nVersion = 2
        msg.append(contentsOf: serializeUInt32LE(0))           // nLockTime = 0
        msg.append(hashPrevouts)
        msg.append(hashAmounts)
        msg.append(hashScripts)
        msg.append(hashSequences)
        msg.append(hashOutputs)
        msg.append(contentsOf: [0x00])                        // spend_type = key-path, no annex
        msg.append(contentsOf: serializeOutpoint(input))       // this input's outpoint
        msg.append(contentsOf: serializeUInt64LE(input.amountSats))
        msg.append(contentsOf: serializeScript(script))        // scriptPubKey length + bytes
        msg.append(contentsOf: serializeUInt32LE(input.sequence))

        return TaggedHash.hash(tag: "TapSighash", data: msg)
    }

    // MARK: - Transaction serialisation (BIP-144 segwit)

    private static func serialize(
        inputs:    [SweepInput],
        outputs:   [SweepOutput],
        witnesses: [[Data]]
    ) -> Data {
        var tx = Data()
        // version
        tx.append(contentsOf: serializeUInt32LE(2))
        // segwit marker + flag
        tx.append(contentsOf: [0x00, 0x01])
        // inputs
        tx.append(contentsOf: varInt(UInt64(inputs.count)))
        for input in inputs {
            tx.append(contentsOf: serializeOutpoint(input))
            tx.append(0x00)  // scriptSig length = 0 (P2TR key-path, empty)
            tx.append(contentsOf: serializeUInt32LE(input.sequence))
        }
        // outputs
        tx.append(contentsOf: varInt(UInt64(outputs.count)))
        for output in outputs {
            tx.append(contentsOf: serializeOutput(output))
        }
        // witness data (one stack per input)
        for witness in witnesses {
            tx.append(contentsOf: varInt(UInt64(witness.count)))
            for item in witness {
                tx.append(contentsOf: varInt(UInt64(item.count)))
                tx.append(item)
            }
        }
        // locktime
        tx.append(contentsOf: serializeUInt32LE(0))
        return tx
    }

    // MARK: - Serialisation helpers

    private static func serializeOutpoint(_ input: SweepInput) -> [UInt8] {
        // txid is stored in internal byte order (little-endian display = reversed)
        // Bitcoin serialisation uses internal byte order directly
        var bytes = [UInt8](input.txid)
        bytes.append(contentsOf: serializeUInt32LE(input.vout))
        return bytes
    }

    private static func serializeOutput(_ output: SweepOutput) -> [UInt8] {
        var bytes = serializeUInt64LE(output.amountSats)
        bytes.append(contentsOf: varInt(UInt64(output.scriptPubKey.count)))
        bytes.append(contentsOf: output.scriptPubKey)
        return bytes
    }

    private static func serializeScript(_ script: Data) -> [UInt8] {
        var bytes = varInt(UInt64(script.count))
        bytes.append(contentsOf: script)
        return bytes
    }

    private static func p2trScript(from xOnlyKey: Data) -> Data {
        Data([0x51, 0x20]) + xOnlyKey   // OP_1 PUSH32 <key>
    }

    private static func sha256(_ bytes: [UInt8]) -> Data {
        Data(SHA256.hash(data: Data(bytes)))
    }

    private static func varInt(_ n: UInt64) -> [UInt8] {
        switch n {
        case 0..<0xFD:   return [UInt8(n)]
        case 0xFD..<0x10000:
            return [0xFD, UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)]
        case 0x10000..<0x100000000:
            return [0xFE] + serializeUInt32LE(UInt32(n))
        default:
            return [0xFF] + serializeUInt64LE(n)
        }
    }

    private static func serializeUInt32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v>>8)&0xFF), UInt8((v>>16)&0xFF), UInt8((v>>24)&0xFF)]
    }

    private static func serializeUInt64LE(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> ($0 * 8)) & 0xFF) }
    }
}

// MARK: - Sweep errors

public enum SweepError: Error, LocalizedError {
    case noInputs
    case insufficientFunds(available: UInt64, required: UInt64)
    case invalidDestinationAddress(String)
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            return "No inputs provided for sweep"
        case .insufficientFunds(let avail, let req):
            return "Insufficient funds: have \(avail) sats, need \(req) sats (amount + fee)"
        case .invalidDestinationAddress(let addr):
            return "Invalid destination address: \(addr)"
        case .signingFailed:
            return "Schnorr signing failed"
        }
    }
}

// MARK: - Unsigned transaction (internal)

private struct UnsignedTx {
    let inputs:  [SweepInput]
    let outputs: [SweepOutput]
}

// MARK: - Address decoder (bech32/bech32m → scriptPubKey)

public enum AddressDecoder {

    /// Convert a Bitcoin address string to its scriptPubKey bytes.
    /// Supports: P2TR (bc1p...), P2WPKH (bc1q...), P2WSH (bc1q... 32-byte),
    ///           P2PKH (1...), P2SH (3...) on mainnet + testnet equivalents.
    public static func toScriptPubKey(_ address: String) throws -> Data {
        let lower = address.lowercased().trimmingCharacters(in: .whitespaces)

        // ── Native SegWit (bech32 / bech32m) ────────────────────────────────
        if lower.hasPrefix("bc1") || lower.hasPrefix("tb1") || lower.hasPrefix("bcrt1") {
            return try decodeSegwitAddress(lower)
        }

        // ── Legacy base58check ────────────────────────────────────────────────
        if let scriptPubKey = tryDecodeBase58Check(address) {
            return scriptPubKey
        }

        throw SweepError.invalidDestinationAddress(address)
    }

    // MARK: - SegWit address decode

    private static func decodeSegwitAddress(_ address: String) throws -> Data {
        // Find the separator between HRP and data
        guard let sepIdx = address.lastIndex(of: "1") else {
            throw SweepError.invalidDestinationAddress(address)
        }
        let hrp      = String(address[..<sepIdx])
        let dataPart = String(address[address.index(after: sepIdx)...])

        // Decode bech32/bech32m charset
        let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        var fiveBit = [UInt8]()
        for c in dataPart {
            guard let idx = charset.firstIndex(of: c) else {
                throw SweepError.invalidDestinationAddress(address)
            }
            fiveBit.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }

        guard fiveBit.count >= 7 else { throw SweepError.invalidDestinationAddress(address) }

        // First 5-bit group is the witness version
        let witnessVersion = fiveBit[0]
        guard witnessVersion <= 16 else { throw SweepError.invalidDestinationAddress(address) }

        // Convert remaining groups (minus 6-byte checksum) from 5-bit to 8-bit
        let dataGroups = Array(fiveBit[1..<(fiveBit.count - 6)])
        let witnessProgram = try Bech32m.convertBits(dataGroups, from: 5, to: 8, pad: false)

        // Validate program length
        switch witnessVersion {
        case 0:  // P2WPKH (20) or P2WSH (32)
            guard witnessProgram.count == 20 || witnessProgram.count == 32 else {
                throw SweepError.invalidDestinationAddress(address)
            }
        case 1:  // P2TR (32)
            guard witnessProgram.count == 32 else {
                throw SweepError.invalidDestinationAddress(address)
            }
        default:
            guard witnessProgram.count >= 2 && witnessProgram.count <= 40 else {
                throw SweepError.invalidDestinationAddress(address)
            }
        }

        // Encode as scriptPubKey: OP_n PUSH<len> <program>
        // OP_0 = 0x00, OP_1..OP_16 = 0x51..0x60
        let opcode: UInt8 = witnessVersion == 0 ? 0x00 : (0x50 + witnessVersion)
        var script = Data([opcode, UInt8(witnessProgram.count)])
        script.append(contentsOf: witnessProgram)
        return script
    }

    // MARK: - Legacy base58check (P2PKH, P2SH)

    private static func tryDecodeBase58Check(_ address: String) -> Data? {
        guard let decoded = base58Decode(address), decoded.count >= 4 else { return nil }

        let payload  = decoded.dropLast(4)
        let checksum = decoded.suffix(4)

        // Verify checksum (SHA256d of payload)
        let hash1 = Data(SHA256.hash(data: payload))
        let hash2 = Data(SHA256.hash(data: hash1))
        guard hash2.prefix(4) == checksum else { return nil }

        guard payload.count >= 1 else { return nil }
        let version = payload[0]
        let hash    = payload.dropFirst()

        switch version {
        case 0x00:  // Mainnet P2PKH
            guard hash.count == 20 else { return nil }
            return Data([0x76, 0xA9, 0x14]) + hash + Data([0x88, 0xAC])
        case 0x05:  // Mainnet P2SH
            guard hash.count == 20 else { return nil }
            return Data([0xA9, 0x14]) + hash + Data([0x87])
        case 0x6F:  // Testnet P2PKH
            guard hash.count == 20 else { return nil }
            return Data([0x76, 0xA9, 0x14]) + hash + Data([0x88, 0xAC])
        case 0xC4:  // Testnet P2SH
            guard hash.count == 20 else { return nil }
            return Data([0xA9, 0x14]) + hash + Data([0x87])
        default:
            return nil
        }
    }

    private static func base58Decode(_ s: String) -> Data? {
        let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        var result = [UInt8](repeating: 0, count: 32)  // max size
        var bytes  = [UInt8]()
        var leadingZeros = 0

        for c in s {
            guard let idx = alphabet.firstIndex(of: c) else { return nil }
            var carry = alphabet.distance(from: alphabet.startIndex, to: idx)
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                carry += 58 * Int(bytes[i])
                bytes[i] = UInt8(carry & 0xFF)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }
        for c in s {
            if c == "1" { leadingZeros += 1 } else { break }
        }
        let leading = [UInt8](repeating: 0, count: leadingZeros)
        return Data(leading + bytes)
    }
}

