package box

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
)

// The box's accounts (One Vault addendum A.3): list, add watch-only, make a
// join code and remove are the first account's; asking "does this box hold
// me" and joining with a code are open to any signer, since the joining
// account is not on the box yet. Its own NIP-98 signature is the proof that
// it holds its key; a secret key is never sent.

const nsecRefused = "That is a secret key (nsec). Never paste it anywhere: paste the npub instead."

func looksLikeNsec(s string) bool {
	return strings.HasPrefix(strings.TrimPrefix(strings.TrimSpace(s), "nostr:"), "nsec")
}

func (a *API) accountsReady(w http.ResponseWriter) bool {
	if a.Accounts == nil || a.JoinCodes == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "this box can't hold more accounts"})
		return false
	}
	return true
}

func accountErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, ErrAccountExists), errors.Is(err, ErrFirstAccount):
		writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
	case errors.Is(err, ErrNoAccount):
		writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
	default:
		log.Printf("box: accounts: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the box couldn't save its accounts; check its logs"})
	}
}

// npubBody reads {"npub": "...", "name": "..."}; false after answering.
func npubBody(w http.ResponseWriter, body []byte) (npub, name string, ok bool) {
	var req struct {
		Npub string `json:"npub"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(body, &req); err != nil || strings.TrimSpace(req.Npub) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": `body must be {"npub": "npub1..."}`})
		return "", "", false
	}
	if looksLikeNsec(req.Npub) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": nsecRefused})
		return "", "", false
	}
	return req.Npub, req.Name, true
}

func init() {
	handle("GET /api/box/accounts", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		if !a.accountsReady(w) {
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"accounts": a.Accounts.List()})
	})

	// me: whether this box holds the signer, and how. The web app asks it
	// right after sign-in, so an account the box does not hold sees "enter a
	// code" instead of an empty Vault.
	handle("GET /api/box/accounts/me", Anyone, func(a *API, w http.ResponseWriter, _ *http.Request, c Caller, _ []byte) {
		state := StateNone
		switch {
		case c.First:
			state = StateFirst
		case a.Accounts != nil:
			state = a.Accounts.StateOf(c.Pubkey)
		}
		writeJSON(w, http.StatusOK, map[string]string{"npub": npubOfHex(c.Pubkey), "state": state})
	})

	handle("POST /api/box/accounts/code", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, _ []byte) {
		if !a.accountsReady(w) {
			return
		}
		code, exp, err := a.JoinCodes.New()
		if err != nil {
			log.Printf("box: join code: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "the box couldn't make a code"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"code": code, "expiresAt": exp.Unix()})
	})

	// join: the signer becomes a signed-in account with a code the first
	// account made. Already signed in: nothing to do and the code is kept.
	handle("POST /api/box/accounts/join", Anyone, func(a *API, w http.ResponseWriter, r *http.Request, c Caller, body []byte) {
		if !a.accountsReady(w) {
			return
		}
		var req struct {
			Code string `json:"code"`
			Name string `json:"name"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": `body must be {"code": "XXXX-XXXX-XXXX"}`})
			return
		}
		if looksLikeNsec(req.Code) || looksLikeNsec(req.Name) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": nsecRefused})
			return
		}
		if c.First {
			accountErr(w, ErrFirstAccount)
			return
		}
		if c.SignedIn {
			writeJSON(w, http.StatusOK, map[string]any{"npub": npubOfHex(c.Pubkey), "state": StateSignedIn, "already": true})
			return
		}
		if err := a.JoinCodes.Redeem(clientOf(r), req.Code); err != nil {
			status := http.StatusForbidden
			if errors.Is(err, ErrJoinCodeTooMany) {
				status = http.StatusTooManyRequests
				w.Header().Set("Retry-After", "60")
			}
			log.Printf("box: join refused for %s: %v", npubOfHex(c.Pubkey), err)
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		view, err := a.Accounts.Join(c.Pubkey, req.Name)
		if err != nil {
			accountErr(w, err)
			return
		}
		log.Printf("box: %s joined as a signed-in account", view.Npub)
		writeJSON(w, http.StatusOK, view)
	})

	handle("POST /api/box/accounts/add", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		if !a.accountsReady(w) {
			return
		}
		npub, name, ok := npubBody(w, body)
		if !ok {
			return
		}
		if _, _, err := ParseOwner(npub); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "That isn't an npub. Paste the account's public key (npub1…)."})
			return
		}
		view, err := a.Accounts.AddWatchOnly(npub, name)
		if err != nil {
			accountErr(w, err)
			return
		}
		log.Printf("box: %s added watch-only", view.Npub)
		writeJSON(w, http.StatusOK, view)
	})

	// remove: off the box's lists; its notes and files stay (no erase).
	handle("POST /api/box/accounts/remove", FirstAccount, func(a *API, w http.ResponseWriter, _ *http.Request, _ Caller, body []byte) {
		if !a.accountsReady(w) {
			return
		}
		npub, _, ok := npubBody(w, body)
		if !ok {
			return
		}
		if _, _, err := ParseOwner(npub); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "That isn't an npub. Paste the account's public key (npub1…)."})
			return
		}
		if err := a.Accounts.Remove(npub); err != nil {
			accountErr(w, err)
			return
		}
		log.Printf("box: %s removed; its notes and files stay", npub)
		writeJSON(w, http.StatusOK, map[string]any{"removed": npub, "kept": "notes and files"})
	})
}
