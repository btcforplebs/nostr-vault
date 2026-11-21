//go:build cshared

package main

import "C"

import (
	"fmt"
	"log/slog"

	"github.com/nbd-wtf/go-nostr"
	"github.com/nbd-wtf/go-nostr/nip04"
	"github.com/nbd-wtf/go-nostr/nip44"
)

// Key and message-encryption exports, moved out of cshared.go unchanged.

//export GenerateKeyPairC
func GenerateKeyPairC() *C.char {
	sk := nostr.GeneratePrivateKey()
	pk, _ := nostr.GetPublicKey(sk)
	return C.CString(fmt.Sprintf("%s:%s", sk, pk))
}

//export GetPublicKeyC
func GetPublicKeyC(sk *C.char) *C.char {
	pk, err := nostr.GetPublicKey(C.GoString(sk))
	if err != nil {
		return nil
	}
	return C.CString(pk)
}

//export EncryptNIP04C
func EncryptNIP04C(plaintext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	sharedSecret, err := nip04.ComputeSharedSecret(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("EncryptNIP04C: ComputeSharedSecret failed", "err", err)
		return nil
	}

	encrypted, err := nip04.Encrypt(C.GoString(plaintext), sharedSecret)
	if err != nil {
		slog.Error("EncryptNIP04C: Encrypt failed", "err", err)
		return nil
	}
	return C.CString(encrypted)
}

//export DeriveTaprootAddressC
func DeriveTaprootAddressC(hexPubKey *C.char) *C.char {
	addr, err := deriveP2TRAddress(C.GoString(hexPubKey))
	if err != nil {
		slog.Error("DeriveTaprootAddressC: failed", "error", err)
		return nil
	}
	return C.CString(addr)
}

//export DecryptNIP04C
func DecryptNIP04C(ciphertext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	sharedSecret, err := nip04.ComputeSharedSecret(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("DecryptNIP04C: ComputeSharedSecret failed", "err", err)
		return nil
	}

	decrypted, err := nip04.Decrypt(C.GoString(ciphertext), sharedSecret)
	if err != nil {
		slog.Error("DecryptNIP04C: Decrypt failed", "err", err)
		return nil
	}
	return C.CString(decrypted)
}

//export EncryptNIP44C
func EncryptNIP44C(plaintext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("EncryptNIP44C: GenerateConversationKey failed", "err", err)
		return nil
	}
	encrypted, err := nip44.Encrypt(C.GoString(plaintext), convKey)
	if err != nil {
		slog.Error("EncryptNIP44C: Encrypt failed", "err", err)
		return nil
	}
	return C.CString(encrypted)
}

//export DecryptNIP44C
func DecryptNIP44C(ciphertext *C.char, pubkey *C.char, privkey *C.char) *C.char {
	convKey, err := nip44.GenerateConversationKey(C.GoString(pubkey), C.GoString(privkey))
	if err != nil {
		slog.Error("DecryptNIP44C: GenerateConversationKey failed", "err", err)
		return nil
	}
	decrypted, err := nip44.Decrypt(C.GoString(ciphertext), convKey)
	if err != nil {
		slog.Error("DecryptNIP44C: Decrypt failed", "err", err)
		return nil
	}
	return C.CString(decrypted)
}
