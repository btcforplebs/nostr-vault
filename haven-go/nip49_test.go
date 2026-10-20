package main

import (
	"bytes"
	"crypto/rand"
	"errors"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/scrypt"
)

// nip49TestPayload builds a version-2 payload the way EncryptNIP49C does,
// with the cost byte set to logN but the key derived at deriveLogN, so a
// test can name an expensive cost without paying for it.
func nip49TestPayload(t *testing.T, key, password []byte, logN, deriveLogN byte) []byte {
	t.Helper()
	salt := make([]byte, 16)
	nonce := make([]byte, chacha20poly1305.NonceSizeX)
	rand.Read(salt)
	rand.Read(nonce)
	dk, err := scrypt.Key(password, salt, 1<<int(deriveLogN), 8, 1, 32)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := chacha20poly1305.NewX(dk)
	if err != nil {
		t.Fatal(err)
	}
	payload := []byte{0x02, logN}
	payload = append(payload, salt...)
	payload = append(payload, nonce...)
	return append(payload, aead.Seal(nil, nonce, key, nil)...)
}

func TestDecryptNIP49PayloadRoundTrip(t *testing.T) {
	key := bytes.Repeat([]byte{0x35}, 32)
	pw := []byte("correct horse")
	got, err := decryptNIP49Payload(nip49TestPayload(t, key, pw, 10, 10), pw)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, key) {
		t.Fatalf("got %x, want %x", got, key)
	}
}

// A pasted ncryptsec chooses its own scrypt cost. Out-of-range values must be
// refused before scrypt runs: logN 40 asks for ~1 TB and kills the app.
// logN 0 comes first and failures are fatal, so a build without the guard
// fails on the cheap case before it can try to allocate for 23 (8 GiB).
func TestDecryptNIP49PayloadRejectsLogNOutOfRange(t *testing.T) {
	key := bytes.Repeat([]byte{0x35}, 32)
	pw := []byte("correct horse")
	for _, logN := range []byte{0, 23, 40, 63, 255} {
		_, err := decryptNIP49Payload(nip49TestPayload(t, key, pw, logN, 10), pw)
		if !errors.Is(err, errNIP49LogN) {
			t.Fatalf("logN %d: got %v, want errNIP49LogN", logN, err)
		}
	}
}
