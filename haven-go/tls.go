package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"fmt"
	"log"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// getOrCreateSelfSignedCert generates or loads a self-signed certificate.
// It stores the cert and key in the app's data directory.
// Returns the certificate file path and key file path, or an error.
func getOrCreateSelfSignedCert(dataDir string) (string, string, error) {
	certPath := filepath.Join(dataDir, "server.crt")
	keyPath := filepath.Join(dataDir, "server.key")

	// If cert and key already exist, return them
	if _, errCert := os.Stat(certPath); errCert == nil {
		if _, errKey := os.Stat(keyPath); errKey == nil {
			log.Println("📝 Using existing self-signed certificate")
			return certPath, keyPath, nil
		}
	}

	log.Println("🔐 Generating new self-signed certificate...")

	// Generate private key
	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return "", "", fmt.Errorf("failed to generate private key: %w", err)
	}

	// Create certificate template
	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Haven"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().AddDate(10, 0, 0), // Valid for 10 years
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	// Self-sign the certificate
	certBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &privateKey.PublicKey, privateKey)
	if err != nil {
		return "", "", fmt.Errorf("failed to create certificate: %w", err)
	}

	// Encode to PEM
	privateKeyBytes, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return "", "", fmt.Errorf("failed to marshal private key: %w", err)
	}

	// Write certificate to file (certBytes is already DER-encoded)
	if err := os.WriteFile(certPath, []byte(pemEncode("CERTIFICATE", certBytes)), 0644); err != nil {
		return "", "", fmt.Errorf("failed to write cert file: %w", err)
	}

	// Write private key to file
	if err := os.WriteFile(keyPath, []byte(pemEncode("PRIVATE KEY", privateKeyBytes)), 0600); err != nil {
		return "", "", fmt.Errorf("failed to write key file: %w", err)
	}

	log.Println("✅ Self-signed certificate generated")
	return certPath, keyPath, nil
}

// pemEncode encodes data in PEM format
func pemEncode(blockType string, data []byte) string {
	return fmt.Sprintf("-----BEGIN %s-----\n%s\n-----END %s-----\n",
		blockType,
		// Base64 encode and wrap at 64 chars per line
		formatPEM(data),
		blockType,
	)
}

// formatPEM formats raw bytes into base64 with 64-char line wrapping
func formatPEM(data []byte) string {
	encoded := base64.StdEncoding.EncodeToString(data)
	var result string
	for i := 0; i < len(encoded); i += 64 {
		if i+64 < len(encoded) {
			result += encoded[i : i+64]
		} else {
			result += encoded[i:]
		}
		result += "\n"
	}
	return result
}
