package wallet

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/bits"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut10"
	"github.com/elnosh/gonuts/cashu/nuts/nut12"
	"github.com/elnosh/gonuts/crypto"
)

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// newOutputs builds one blinded message per amount. lockTo, when set, is a
// compressed (33-byte hex) or x-only (32-byte hex) pubkey: the outputs become
// NUT-11 P2PK secrets locked to it (nutzaps).
func newOutputs(ks Keyset, amounts []uint64, role OutputRole, lockTo string) ([]PendingOutput, error) {
	return newLockedOutputs(ks, amounts, role, lockTo, nil)
}

// newLockedOutputs is newOutputs with NUT-11 tags (refund, locktime) on the
// P2PK secrets.
func newLockedOutputs(ks Keyset, amounts []uint64, role OutputRole, lockTo string, lockTags [][]string) ([]PendingOutput, error) {
	out := make([]PendingOutput, 0, len(amounts))
	for _, amt := range amounts {
		if role != RoleChange {
			if _, ok := ks.Keys[amt]; !ok {
				return nil, fmt.Errorf("keyset %s has no key for amount %d", ks.ID, amt)
			}
		}
		var secret string
		var err error
		if lockTo != "" {
			if lockTo, err = normalizeLockKey(lockTo); err != nil {
				return nil, err
			}
			secret, err = nut10.NewSecretFromSpendingCondition(nut10.SpendingCondition{Kind: nut10.P2PK, Data: lockTo, Tags: lockTags})
		} else {
			secret, err = randomHex(32)
		}
		if err != nil {
			return nil, err
		}
		r, err := secp256k1.GeneratePrivateKey()
		if err != nil {
			return nil, err
		}
		B, _, err := crypto.BlindMessage(secret, r)
		if err != nil {
			return nil, err
		}
		out = append(out, PendingOutput{
			Amount:   amt,
			KeysetID: ks.ID,
			Secret:   secret,
			R:        hex.EncodeToString(r.Serialize()),
			B:        hex.EncodeToString(B.SerializeCompressed()),
			Role:     role,
		})
	}
	return out, nil
}

// blankOutputs builds NUT-08 change outputs able to carry back up to overpay
// sats. The mint sets their amounts.
func blankOutputs(ks Keyset, overpay uint64) ([]PendingOutput, error) {
	if overpay == 0 {
		return nil, nil
	}
	n := bits.Len64(overpay)
	amounts := make([]uint64, n)
	for i := range amounts {
		amounts[i] = 1
	}
	return newOutputs(ks, amounts, RoleChange, "")
}

func blinded(outs []PendingOutput) cashu.BlindedMessages {
	bm := make(cashu.BlindedMessages, len(outs))
	for i, o := range outs {
		bm[i] = cashu.BlindedMessage{Amount: o.Amount, B_: o.B, Id: o.KeysetID}
	}
	return bm
}

// unblindOne turns the mint's signature on one of our outputs into a proof.
// It checks the keyset, the amount and, when the mint sends one, the NUT-12
// DLEQ proof (a wallet can't check a blind signature any other way).
func unblindOne(o PendingOutput, sig cashu.BlindedSignature, sets map[string]Keyset) (cashu.Proof, error) {
	ks, ok := sets[sig.Id]
	if !ok {
		return cashu.Proof{}, fmt.Errorf("signature from unknown keyset %s", sig.Id)
	}
	if sig.Id != o.KeysetID {
		return cashu.Proof{}, fmt.Errorf("signature keyset %s, asked for %s", sig.Id, o.KeysetID)
	}
	if o.Role != RoleChange && sig.Amount != o.Amount {
		return cashu.Proof{}, fmt.Errorf("signature amount %d, asked for %d", sig.Amount, o.Amount)
	}
	K, err := ks.pubkey(sig.Amount)
	if err != nil {
		return cashu.Proof{}, err
	}
	if sig.DLEQ != nil && !nut12.VerifyBlindSignatureDLEQ(*sig.DLEQ, K, o.B, sig.C_) {
		return cashu.Proof{}, fmt.Errorf("mint signature failed its DLEQ check")
	}
	cb, err := hex.DecodeString(sig.C_)
	if err != nil {
		return cashu.Proof{}, err
	}
	C_, err := secp256k1.ParsePubKey(cb)
	if err != nil {
		return cashu.Proof{}, err
	}
	rb, err := hex.DecodeString(o.R)
	if err != nil {
		return cashu.Proof{}, err
	}
	r := secp256k1.PrivKeyFromBytes(rb)
	C := crypto.UnblindSignature(C_, r, K)
	p := cashu.Proof{
		Amount: sig.Amount,
		Id:     sig.Id,
		Secret: o.Secret,
		C:      hex.EncodeToString(C.SerializeCompressed()),
	}
	if sig.DLEQ != nil {
		p.DLEQ = &cashu.DLEQProof{E: sig.DLEQ.E, S: sig.DLEQ.S, R: o.R}
	}
	return p, nil
}

// unblindAll pairs signatures with outputs by position (NUT-03/04/05 return
// them in request order). NUT-08 may return fewer change signatures than
// blank outputs.
func unblindAll(outs []PendingOutput, sigs cashu.BlindedSignatures, sets map[string]Keyset, allowFewer bool) ([]cashu.Proof, error) {
	if len(sigs) > len(outs) || (!allowFewer && len(sigs) != len(outs)) {
		return nil, fmt.Errorf("mint returned %d signatures for %d outputs", len(sigs), len(outs))
	}
	proofs := make([]cashu.Proof, len(sigs))
	for i, s := range sigs {
		p, err := unblindOne(outs[i], s, sets)
		if err != nil {
			return nil, err
		}
		proofs[i] = p
	}
	return proofs, nil
}

// proofY is hash_to_curve(secret), compressed hex: the id NUT-07 uses.
func proofY(secret string) (string, error) {
	Y, err := crypto.HashToCurve([]byte(secret))
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(Y.SerializeCompressed()), nil
}

// splitAmount is the power-of-two split of amount, smallest first.
func splitAmount(amount uint64) []uint64 { return cashu.AmountSplit(amount) }

// normalizeLockKey turns a NIP-61 10019 pubkey (x-only, or already 02/03
// compressed) into the 33-byte compressed hex NUT-11 needs.
func normalizeLockKey(k string) (string, error) {
	b, err := hex.DecodeString(k)
	if err != nil {
		return "", fmt.Errorf("lock key is not hex")
	}
	if len(b) == 32 {
		b = append([]byte{0x02}, b...)
	}
	pk, err := secp256k1.ParsePubKey(b)
	if err != nil {
		return "", fmt.Errorf("lock key is not a secp256k1 pubkey")
	}
	return hex.EncodeToString(pk.SerializeCompressed()), nil
}
