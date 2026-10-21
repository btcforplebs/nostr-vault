package main

import (
	"errors"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/scrypt"
)

// NIP-49 decryption, kept out of cshared.go so it builds (and is tested)
// without cgo. DecryptNIP49C decodes the bech32 and hands the payload here.

// nip49MaxLogN caps the scrypt cost read from an ncryptsec. scrypt needs
// 128*r*2^logN bytes, so logN 40 asks for ~1 TB and aborts the process instead
// of failing. NIP-49 writes 16; nothing above 22 (4 GiB) is usable on a phone.
const nip49MaxLogN = 22

var (
	errNIP49Short   = errors.New("nip49: payload too short")
	errNIP49Version = errors.New("nip49: unsupported version")
	errNIP49LogN    = errors.New("nip49: logN out of range")
	errNIP49KeySize = errors.New("nip49: decrypted key is not 32 bytes")
)

// decryptNIP49Payload decrypts a version-2 NIP-49 payload:
// version(1) + logN(1) + salt(16) + nonce(24) + ciphertext(48 = 32+16).
func decryptNIP49Payload(payload, password []byte) ([]byte, error) {
	if len(payload) < 1+1+16+24+32+16 {
		return nil, errNIP49Short
	}
	if payload[0] != 0x02 {
		return nil, errNIP49Version
	}

	logN := payload[1]
	if logN < 1 || logN > nip49MaxLogN {
		return nil, errNIP49LogN
	}
	N := 1 << int(logN)
	salt := payload[2:18]
	nonce := payload[18:42]
	ciphertext := payload[42:]

	derivedKey, err := scrypt.Key(password, salt, N, 8, 1, 32)
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.NewX(derivedKey)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, err
	}
	if len(plaintext) != 32 {
		return nil, errNIP49KeySize
	}
	return plaintext, nil
}
