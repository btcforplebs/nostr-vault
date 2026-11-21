package box

import (
	"net/http"
	"strings"
)

// Level is who may use a box API route (One Vault addendum A.3).
type Level int

const (
	// FirstAccount: only the box's first account (box/owner, NV_OWNER), the
	// one that claimed it and runs it: update, move, restart, backup and
	// restore, adding and removing accounts.
	FirstAccount Level = iota
	// SignedIn: any account that has signed in to this box. Nothing uses it
	// yet: until the box holds several accounts (E8, E9) the NIP-98 check
	// admits the first account only, and every route is FirstAccount.
	SignedIn
)

// Caller is who asked: the account whose NIP-98 proof the request carried.
type Caller struct {
	Pubkey string // hex
	First  bool   // the box's first account
}

// may: c may use a route of level l.
func (c Caller) may(l Level) bool {
	return c.First || l == SignedIn
}

// routeFunc answers one checked box API route for caller c. body is the
// request body the NIP-98 check already read.
type routeFunc func(a *API, w http.ResponseWriter, r *http.Request, c Caller, body []byte)

type route struct {
	level Level
	serve routeFunc
}

// boxRoutes maps "METHOD /api/box/path" to its level and handler. Each
// routes_*.go file registers its own area's routes from init, so a new area
// is a new file and never an edit to a shared switch.
var boxRoutes = map[string]route{}

func handle(path string, level Level, f routeFunc) {
	if _, dup := boxRoutes[path]; dup {
		panic("box: route registered twice: " + path)
	}
	boxRoutes[path] = route{level: level, serve: f}
}

// callerOf: who a request that passed the NIP-98 check came from. Today the
// check admits the first account only (OwnerAuth), so the caller is always
// it; when added accounts can sign in (E9) the check will name the signer.
func (a *API) callerOf(*http.Request) Caller {
	return Caller{Pubkey: strings.ToLower(a.Auth.OwnerHex), First: true}
}
