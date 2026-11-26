// Package wallet is the engine half of the built-in Cashu wallet (design:
// RESEARCH/NV_CASHU_WALLET_DESIGN_2026_11_25.md §2, PR E1).
//
// It talks to Cashu mints (NUT-01..07, 09, 11, 12), keeps the proofs, and runs
// mint (Lightning in), melt (Lightning out), swap (send/receive, P2PK) and
// checkstate. It never signs Nostr events and never sees the account key: the
// NIP-60/61 event layer (E2, events.go, nip60_*.go, nip61.go) builds unsigned
// templates and reads decrypted events, and the app bridges (E3) sit on top.
//
// Money rule (§4.3): every operation writes what it is about to do, including
// the blinded outputs and their secrets, to the Store BEFORE it calls the mint.
// If the app dies at any point after that, Recover finishes or undoes the
// operation from the journal: inputs the mint marks spent are dropped, outputs
// it signed are recovered with NUT-09 restore, and inputs it never saw go back
// into the balance. Nothing is ever dropped from the journal while the mint's
// answer is unknown.
//
// Only gonuts' light packages are used (cashu, nuts, crypto). gonuts/mint and
// gonuts/wallet pull in lnd, sqlite (CGO) and bbolt, so they are not imported.
package wallet
