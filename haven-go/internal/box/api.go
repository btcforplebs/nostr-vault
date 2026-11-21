package box

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
)

// API is the box API under /api/box/. Every route needs a NIP-98 proof
// signed by one of the box's accounts: the first account (NV_OWNER) for
// most, any signed-in account for some (routes.go levels). A key the box
// does not hold gets nothing, not even the version, except the two Anyone
// routes that let an account ask whether it is held and join with a code.
type API struct {
	Auth    *OwnerAuth
	Version string
	Started time.Time
	Mesh    MeshID // the box's one npub, the mesh's
	Owner   string // npub
	// RelayURL is NV_RELAY_URL, the box's own web address if it has one
	// (Config.RelayURL); the box screen's Public on the web part shows it.
	RelayURL string

	Engine     interface{ State() EngineState }
	MeshStatus string // path of the mesh status file
	Storage    *StorageMeter
	Devices    *Devices
	Mover      *Mover
	Updater    *Updater
	// Accounts and JoinCodes hold the added accounts (accounts_auth.go,
	// join_code.go). Nil: the first account alone.
	Accounts  *AccountStore
	JoinCodes *JoinCodes
}

func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	proof, err := a.Auth.Verify(r)
	if err != nil {
		var ae *AuthError
		status := http.StatusUnauthorized
		if errors.As(err, &ae) {
			status = ae.Status
		}
		if status == http.StatusUnauthorized {
			w.Header().Set("WWW-Authenticate", `Nostr`)
		}
		writeJSON(w, status, map[string]string{"error": err.Error()})
		return
	}

	c := a.callerOf(proof.Pubkey)
	rt, ok := boxRoutes[r.Method+" "+r.URL.Path]
	// Someone the box does not hold (or holds watch-only) learns nothing,
	// not even which routes exist, past the Anyone routes.
	if !c.member() && (!ok || rt.level != Anyone) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "only the owner may use the box API"})
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no such box API route"})
		return
	}
	if !c.may(rt.level) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "only the box's first account may do this"})
		return
	}
	if !a.Auth.FirstUse(proof.ID) {
		w.Header().Set("WWW-Authenticate", `Nostr`)
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "authorization was already used"})
		return
	}
	rt.serve(a, w, r, c, proof.Body)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func itoa(n int) string     { return strconv.Itoa(n) }
func itoa64(n int64) string { return strconv.FormatInt(n, 10) }
