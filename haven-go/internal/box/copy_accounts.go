package box

import "time"

// Which accounts a box offers another device in a mesh copy (One Vault
// addendum A, E11). The engine sends the accounts its copy-accounts.json
// lists that are also its own (haven-go copyv2_accounts.go
// localCopyAccounts); on a Mac the app writes that file with the accounts
// that can sign there. Nothing wrote it on a box, so the engine fell back
// to the first account alone: a signed-in added account's notes went along
// only as "brought" (stored, hidden) and the other device was never offered
// the account.
//
// A box holds no keys, so its equivalent of "can sign here" is "signed in to
// this box" (accounts.go). The box writes the file on every engine start:
// the first account, then each signed-in account, with its name. Watch-only
// accounts are never offered, as on a Mac (an npub added alone is often
// someone else's; a device that took the offer would make it its own).
//
// Accounts a copy from another device offers the box are merged into the
// same file by the engine until the next start; a box has no screen to take
// those offers, so their notes stay brought until the account joins.

// copyAccountsName is the engine's copyAccountsFile, in the vault folder.
const copyAccountsName = "copy-accounts.json"

type copyAccountJSON struct {
	Npub string `json:"npub"`
	Name string `json:"name,omitempty"`
}

type copyAccountsJSON struct {
	V         int               `json:"v"`
	UpdatedAt int64             `json:"updated_at"`
	Accounts  []copyAccountJSON `json:"accounts"`
}

// copyAccountsFor: the file's content for the first account ownerNpub plus
// added, at now.
func copyAccountsFor(ownerNpub string, added []Account, now time.Time) copyAccountsJSON {
	names := map[string]string{}
	for _, a := range added {
		if a.Name != "" {
			names[a.Npub] = a.Name
		}
	}
	out := copyAccountsJSON{V: 1, UpdatedAt: now.Unix()}
	for _, n := range ListsFor(ownerNpub, added).Readers {
		out.Accounts = append(out.Accounts, copyAccountJSON{Npub: n, Name: names[n]})
	}
	return out
}
